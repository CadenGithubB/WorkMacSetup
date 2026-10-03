import Foundation
import Darwin

struct ChromeProfileRecord {
    let name: String
    let directory: String
}

struct ChromeProfileCreationResult {
    let created: [ChromeProfileRecord]
    let skipped: [ChromeProfileRecord]
    let backupURL: URL?
}

enum ChromeProfileError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Chrome's existing profile names, read without changing anything. The app
/// uses this to flag client names before setup runs.
struct ChromeExistingProfiles {
    /// Normalized profile name to the Chrome profile directories using it.
    let existing: [String: Set<String>]
    /// Normalized client name to the directory this app created for it.
    let owned: [String: String]

    static let none = ChromeExistingProfiles(existing: [:], owned: [:])

    /// The names that already belong to a Chrome profile this app did not
    /// create. Setup refuses these, so the app asks for a rename or removal.
    func conflicts(in names: [String]) -> [String] {
        names.filter { name in
            let key = ChromeProfileCreator.normalizedName(name)
            guard !key.isEmpty else { return false }
            var matches = existing[key, default: []]
            if let directory = owned[key] { matches.remove(directory) }
            return !matches.isEmpty
        }
    }
}

/// Creates local profiles without starting Chrome or modifying existing profiles.
/// The root and process check are injected only in this engine for fixture tests.
final class ChromeProfileCreator {
    private struct Client {
        let name: String
        let key: String
        let startURL: String?
        let color: Int32?
    }

    private struct Plan {
        let created: [ChromeProfileRecord]
        let skipped: [ChromeProfileRecord]
        let preferences: [String: Data]
        let localStateBefore: Data?
        let manifestBefore: Data?
        let localStateAfter: Data
        let manifestAfter: Data
    }

    private let fileManager = FileManager.default
    private let rootURL: URL
    private let supportURL: URL
    private let isChromeRunning: () throws -> Bool
    private var localStateURL: URL { rootURL.appendingPathComponent("Local State") }
    private var manifestURL: URL { supportURL.appendingPathComponent("chrome-profiles.json") }
    private var journalURL: URL { supportURL.appendingPathComponent("chrome-profiles-transaction.json") }

    init(rootURL: URL, supportURL: URL, isChromeRunning: @escaping () throws -> Bool) {
        // On macOS standardizedFileURL may turn an existing /private/tmp path
        // into the /tmp symlink. Keep explicit paths for strict ancestor checks.
        self.rootURL = rootURL
        self.supportURL = supportURL
        self.isChromeRunning = isChromeRunning
    }

    func run(clientsTSV: String, dryRun: Bool = false) throws -> ChromeProfileCreationResult {
        let clients = try parseClients(clientsTSV)
        try ensureChromeClosed()
        try validateLocations()
        try ensureNoPendingTransaction()
        let plan = try makePlan(clients)
        if dryRun || plan.created.isEmpty {
            return ChromeProfileCreationResult(created: plan.created, skipped: plan.skipped, backupURL: nil)
        }

        // No target data is changed until the entire input and plan are valid.
        try ensureChromeClosed()
        try createPrivateDirectories(supportURL)
        let lock = try acquireLock()
        defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
        try validateLocations()
        try ensureNoPendingTransaction()
        try ensureUnchanged(localStateURL, expected: plan.localStateBefore)
        try ensureUnchanged(manifestURL, expected: plan.manifestBefore)
        try ensureChromeClosed()

        let backupURL = try createBackup(plan)
        let journal: [String: Any] = [
            "version": 1,
            "status": "pending",
            "chrome_root": rootURL.path,
            "backup_directory": backupURL.path,
            "created_directories": plan.created.map(\.directory),
            "local_state_existed": plan.localStateBefore != nil,
            "manifest_existed": plan.manifestBefore != nil
        ]
        try atomicWrite(try jsonData(journal), to: journalURL)

        do {
            try ensureChromeClosed()
            try ensureUnchanged(localStateURL, expected: plan.localStateBefore)
            try createPrivateDirectories(rootURL)
            for record in plan.created {
                let directory = rootURL.appendingPathComponent(record.directory, isDirectory: true)
                guard try attributesIfPresent(directory) == nil else {
                    throw ChromeProfileError.invalid("Profile directory appeared during setup: \(record.directory).")
                }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
                try atomicWrite(plan.preferences[record.directory]!,
                                to: directory.appendingPathComponent("Preferences"))
            }

            // Chrome owns Local State. Register only after the new directories and
            // ownership manifest exist, and refuse to overwrite a changed snapshot.
            try ensureChromeClosed()
            try ensureUnchanged(localStateURL, expected: plan.localStateBefore)
            try ensureUnchanged(manifestURL, expected: plan.manifestBefore)
            try atomicWrite(plan.manifestAfter, to: manifestURL, beforeCommit: {
                try self.validateLocations()
                try self.ensureChromeClosed()
                try self.ensureUnchanged(self.manifestURL, expected: plan.manifestBefore)
                try self.ensureUnchanged(self.localStateURL, expected: plan.localStateBefore)
            })
            try ensureChromeClosed()
            try ensureUnchanged(localStateURL, expected: plan.localStateBefore)
            try atomicWrite(plan.localStateAfter, to: localStateURL, beforeCommit: {
                try self.validateLocations()
                try self.ensureChromeClosed()
                try self.ensureUnchanged(self.localStateURL, expected: plan.localStateBefore)
            })
            try ensureUnchanged(localStateURL, expected: plan.localStateAfter)
            try fileManager.removeItem(at: journalURL)
        } catch {
            throw ChromeProfileError.invalid("Profile creation stopped: \(error.localizedDescription) " +
                "Recovery is required before another run. Preserve \(journalURL.path) and the backups in \(backupURL.path).")
        }
        return ChromeProfileCreationResult(created: plan.created, skipped: plan.skipped, backupURL: backupURL)
    }

    private func parseClients(_ text: String) throws -> [Client] {
        var clients: [Client] = []
        var keys = Set<String>()
        for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("#") && !line.contains("\t") { continue }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 2 || fields.count == 3 else {
                throw ChromeProfileError.invalid("Client line \(offset + 1) must have a name, a tab, a URL, and an optional tab/color.")
            }
            let name = fields[0].trimmingCharacters(in: .whitespaces)
            let key = canonicalName(name)
            guard !name.isEmpty, !key.isEmpty, !containsControlCharacters(name) else {
                throw ChromeProfileError.invalid("Client line \(offset + 1) needs a name containing letters or numbers and no control characters.")
            }
            guard keys.insert(key).inserted else {
                throw ChromeProfileError.invalid("Client line \(offset + 1) duplicates another normalized client name.")
            }
            let startURL = fields[1].trimmingCharacters(in: .whitespaces)
            if !startURL.isEmpty && startURL != "about:blank" {
                guard !containsControlCharacters(startURL),
                      let url = URL(string: startURL),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty else {
                    throw ChromeProfileError.invalid("Client line \(offset + 1) has an invalid start URL. Use http://, https://, or about:blank.")
                }
            }
            let colorText = fields.count == 3 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
            clients.append(Client(name: name, key: key, startURL: startURL.isEmpty ? nil : startURL,
                                  color: try parseColor(colorText, line: offset + 1)))
        }
        guard !clients.isEmpty else { throw ChromeProfileError.invalid("The client list is empty.") }
        return clients
    }

    /// Profile names match regardless of case, accents, and punctuation.
    static func normalizedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
    }

    private func canonicalName(_ name: String) -> String {
        Self.normalizedName(name)
    }

    /// Reads Chrome's profile names and this app's ownership record without
    /// changing anything; Chrome may be open. Unreadable data flags nothing,
    /// and setup itself still refuses a conflicting name.
    func existingProfiles() -> ChromeExistingProfiles {
        var existing: [String: Set<String>] = [:]
        if let data = try? readRegularFile(localStateURL),
           let state = try? decodeObject(data, name: "Chrome Local State"),
           let profile = state["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any] {
            for (directory, rawEntry) in cache {
                guard let entry = rawEntry as? [String: Any], let name = entry["name"] as? String else { continue }
                existing[canonicalName(name), default: []].insert(directory)
            }
        }
        var owned: [String: String] = [:]
        if let data = try? readRegularFile(manifestURL),
           let manifest = try? decodeObject(data, name: "Work Mac Setup profile manifest"),
           let profiles = manifest["profiles"] as? [String: Any] {
            for (key, rawEntry) in profiles {
                if let entry = rawEntry as? [String: Any], let directory = entry["directory"] as? String {
                    owned[key] = directory
                }
            }
        }
        return ChromeExistingProfiles(existing: existing, owned: owned)
    }

    private func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func parseColor(_ value: String, line: Int) throws -> Int32? {
        guard !value.isEmpty else { return nil }
        let colors: [String: UInt32] = [
            "blue": 0x4285F4, "red": 0xDB4437, "green": 0x0F9D58,
            "orange": 0xF4A000, "yellow": 0xFBBC04, "purple": 0xAB47BC,
            "pink": 0xE91E63, "teal": 0x009688, "gray": 0x607D8B, "grey": 0x607D8B
        ]
        let lower = value.lowercased()
        if let rgb = colors[lower] { return Int32(bitPattern: 0xFF000000 | rgb) }
        if lower.range(of: #"^#[0-9a-f]{6}$"#, options: .regularExpression) != nil,
           let rgb = UInt32(lower.dropFirst(), radix: 16) {
            return Int32(bitPattern: 0xFF000000 | rgb)
        }
        throw ChromeProfileError.invalid("Client line \(line) has an unsupported color '\(value)'.")
    }

    private func makePlan(_ clients: [Client]) throws -> Plan {
        let localStateBefore = try readRegularFile(localStateURL)
        let manifestBefore = try readRegularFile(manifestURL)
        var state = try decodeObject(localStateBefore, name: "Chrome Local State")
        let profiles = try dictionary(state, key: "profiles", context: "Chrome Local State")
        if let tombstones = profiles["profile_basenames_deleted"] {
            guard let directories = tombstones as? [String] else {
                throw ChromeProfileError.invalid("Chrome profiles.profile_basenames_deleted must be an array of directory names.")
            }
            // Chromium delete_profile_helper.cc: CleanUpDeletedProfiles removes
            // these directories on startup, including any newly reused basename.
            guard directories.isEmpty else {
                throw ChromeProfileError.invalid("Chrome has profiles pending deletion. Open and fully quit Chrome to finish that cleanup before creating profiles.")
            }
        }
        var profile = try dictionary(state, key: "profile", context: "Chrome Local State")
        var cache = try dictionary(profile, key: "info_cache", context: "Chrome profile metadata")
        let startingProfileIndex: Int
        if let rawCount = profile["profiles_created"] {
            guard let count = rawCount as? NSNumber,
                  CFGetTypeID(count) != CFBooleanGetTypeID(),
                  count.doubleValue >= 0, count.doubleValue <= Double(Int32.max),
                  count.doubleValue.rounded() == count.doubleValue else {
                throw ChromeProfileError.invalid("Chrome profile.profiles_created must be a nonnegative 32-bit integer.")
            }
            startingProfileIndex = max(1, count.intValue)
        } else {
            startingProfileIndex = 1
        }
        var order: [String]
        if let existingOrder = profile["profiles_order"] {
            guard let strings = existingOrder as? [String], Set(strings).count == strings.count else {
                throw ChromeProfileError.invalid("Chrome profile.profiles_order must be an array of unique directory names.")
            }
            order = strings
        } else {
            order = cache.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        var manifest = try decodeObject(manifestBefore, name: "Work Mac Setup profile manifest")
        if manifestBefore != nil {
            guard let version = manifest["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  manifest["profiles"] is [String: Any] else {
                throw ChromeProfileError.invalid("Unsupported Work Mac Setup profile manifest version.")
            }
        }
        var owned = try dictionary(manifest, key: "profiles", context: "Work Mac Setup profile manifest")
        var occupied = Set<String>()
        if try attributesIfPresent(rootURL) != nil {
            for name in try fileManager.contentsOfDirectory(atPath: rootURL.path) {
                occupied.insert(name)
                if name == "Default" || name.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil {
                    try requireDirectory(rootURL.appendingPathComponent(name), mustExist: true)
                }
            }
        }
        var existingNames: [String: Set<String>] = [:]
        for (directory, rawEntry) in cache {
            try validateDirectoryName(directory)
            guard let entry = rawEntry as? [String: Any], let name = entry["name"] as? String,
                  !name.isEmpty else {
                throw ChromeProfileError.invalid("Chrome profile metadata for '\(directory)' has no valid name.")
            }
            try requireDirectory(rootURL.appendingPathComponent(directory), mustExist: true)
            occupied.insert(directory)
            existingNames[canonicalName(name), default: []].insert(directory)
        }
        for directory in order {
            try validateDirectoryName(directory)
            guard cache[directory] != nil else {
                throw ChromeProfileError.invalid("Chrome's profile order refers to unregistered directory '\(directory)'.")
            }
        }
        if localStateBefore == nil && occupied.contains(where: {
            $0 == "Default" || $0.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil
        }) {
            throw ChromeProfileError.invalid("Chrome profile directories exist without Local State. Open and quit Chrome to repair its registration before setup.")
        }

        var ownedDirectories = Set<String>()
        for (key, rawEntry) in owned {
            guard let entry = rawEntry as? [String: Any], let name = entry["name"] as? String,
                  let directory = entry["directory"] as? String,
                  canonicalName(name) == key, !key.isEmpty,
                  directory.range(of: #"^Profile [1-9][0-9]*$"#, options: .regularExpression) != nil,
                  ownedDirectories.insert(directory).inserted,
                  let cacheEntry = cache[directory] as? [String: Any],
                  let cachedName = cacheEntry["name"] as? String,
                  canonicalName(cachedName) == key else {
                throw ChromeProfileError.invalid("The profile ownership manifest is inconsistent. Review it before creating profiles.")
            }
            try requireDirectory(rootURL.appendingPathComponent(directory), mustExist: true)
            // Existing profile files are never read or rewritten, but a replaced
            // symlink must not be treated as a valid app-owned Preferences file.
            guard try readRegularFileMetadata(rootURL.appendingPathComponent(directory).appendingPathComponent("Preferences")) != nil else {
                throw ChromeProfileError.invalid("An app-owned profile is missing its Preferences file: \(directory).")
            }
        }

        var created: [ChromeProfileRecord] = []
        var skipped: [ChromeProfileRecord] = []
        var preferences: [String: Data] = [:]
        // Chromium profile_manager.cc: GenerateNextProfileDirectoryPath uses
        // profile.profiles_created as the next directory number, then increments.
        var nextIndex = startingProfileIndex
        for client in clients {
            if let entry = owned[client.key] as? [String: Any], let directory = entry["directory"] as? String {
                let otherMatches = existingNames[client.key, default: []].subtracting([directory])
                guard otherMatches.isEmpty else {
                    throw ChromeProfileError.invalid("A different Chrome profile already uses the client name '\(client.name)'. Resolve the duplicate in Chrome first.")
                }
                skipped.append(ChromeProfileRecord(name: client.name, directory: directory))
                continue
            }
            guard existingNames[client.key, default: []].isEmpty else {
                throw ChromeProfileError.invalid("A Chrome profile named '\(client.name)' already exists and is not owned by Work Mac Setup. Rename the requested client or resolve the conflict in Chrome.")
            }
            while occupied.contains("Profile \(nextIndex)") {
                guard nextIndex < Int(Int32.max) else { throw ChromeProfileError.invalid("No supported Chrome profile directory number remains.") }
                nextIndex += 1
            }
            guard nextIndex < Int(Int32.max) else { throw ChromeProfileError.invalid("No supported Chrome profile directory number remains.") }
            let directory = "Profile \(nextIndex)"
            nextIndex += 1
            occupied.insert(directory)
            created.append(ChromeProfileRecord(name: client.name, directory: directory))
            owned[client.key] = ["name": client.name, "directory": directory]

            // Chromium: chrome/browser/profiles/profile_attributes_storage.cc
            // and profile_attributes_entry.cc define info_cache and profiles_order.
            // Empty account attributes describe a LOCAL, unsigned-in profile.
            cache[directory] = [
                "name": client.name,
                "avatar_icon": "chrome://theme/IDR_PROFILE_AVATAR_26",
                "is_using_default_name": false,
                "is_using_default_avatar": true,
                "is_ephemeral": false,
                "user_name": "",
                "gaia_id": "",
                "is_consented_primary_account": false
            ]
            order.append(directory)
            var prefs: [String: Any] = [
                "profile": ["name": client.name, "using_default_name": false,
                            "avatar_index": 26, "using_default_avatar": true]
            ]
            if let startURL = client.startURL {
                prefs["session"] = ["restore_on_startup": 4, "startup_urls": [startURL]]
            }
            if let color = client.color {
                // Chromium theme_service.cc: InitFromPrefs / SetThemePrefsForColor;
                // SkColor is persisted as its signed 32-bit ARGB representation.
                prefs["extensions"] = ["theme": ["id": "autogenerated_theme_id"]]
                prefs["autogenerated"] = ["theme": ["color": Int(color)]]
            }
            preferences[directory] = try jsonData(prefs)
        }
        profile["info_cache"] = cache
        profile["profiles_order"] = order
        profile["profiles_created"] = nextIndex
        state["profile"] = profile
        manifest["version"] = 1
        manifest["profiles"] = owned
        return Plan(created: created, skipped: skipped, preferences: preferences,
                    localStateBefore: localStateBefore, manifestBefore: manifestBefore,
                    localStateAfter: try jsonData(state), manifestAfter: try jsonData(manifest))
    }

    private func validateLocations() throws {
        guard rootURL.isFileURL, supportURL.isFileURL,
              !rootURL.pathComponents.contains(".."), !supportURL.pathComponents.contains(".."),
              rootURL != supportURL, !supportURL.path.hasPrefix(rootURL.path + "/"),
              !rootURL.path.hasPrefix(supportURL.path + "/") else {
            throw ChromeProfileError.invalid("Chrome and Work Mac Setup data directories must be separate.")
        }
        try validateAncestors(rootURL)
        try validateAncestors(supportURL)
        try requireDirectory(rootURL, mustExist: false)
        try requireDirectory(supportURL, mustExist: false)
    }

    private func ensureChromeClosed() throws {
        guard try !isChromeRunning() else {
            throw ChromeProfileError.invalid("Quit Google Chrome completely (Chrome > Quit Google Chrome), including its background processes, then run setup again.")
        }
    }

    private func ensureNoPendingTransaction() throws {
        if try attributesIfPresent(journalURL) != nil {
            throw ChromeProfileError.invalid("An unfinished profile transaction requires recovery. Preserve and review \(journalURL.path) and its referenced backups before running setup again.")
        }
    }

    private func validateDirectoryName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\\"), !containsControlCharacters(name) else {
            throw ChromeProfileError.invalid("Chrome contains an unsafe profile directory name.")
        }
    }

    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try fileManager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func validateAncestors(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard let attributes = try attributesIfPresent(current) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ChromeProfileError.invalid("Refusing a non-directory or symbolic-link path: \(current.path).")
            }
        }
    }

    private func requireDirectory(_ url: URL, mustExist: Bool) throws {
        guard let attributes = try attributesIfPresent(url) else {
            if mustExist { throw ChromeProfileError.invalid("Expected Chrome profile directory is missing: \(url.path).") }
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw ChromeProfileError.invalid("Refusing a symbolic link, non-directory, or directory owned by another user: \(url.path).")
        }
    }

    private func readRegularFileMetadata(_ url: URL) throws -> [FileAttributeKey: Any]? {
        guard let attributes = try attributesIfPresent(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw ChromeProfileError.invalid("Refusing a symbolic link, shared file, or file owned by another user: \(url.path).")
        }
        return attributes
    }

    private func readRegularFile(_ url: URL) throws -> Data? {
        guard try readRegularFileMetadata(url) != nil else { return nil }
        return try Data(contentsOf: url)
    }

    private func decodeObject(_ data: Data?, name: String) throws -> [String: Any] {
        guard let data else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ChromeProfileError.invalid("\(name) must contain a JSON object.")
            }
            return object
        } catch {
            throw ChromeProfileError.invalid("Could not read valid JSON from \(name): \(error.localizedDescription)")
        }
    }

    private func dictionary(_ object: [String: Any], key: String, context: String) throws -> [String: Any] {
        guard let value = object[key] else { return [:] }
        guard let dictionary = value as? [String: Any] else {
            throw ChromeProfileError.invalid("\(context).\(key) must be a JSON object.")
        }
        return dictionary
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    private func ensureUnchanged(_ url: URL, expected: Data?) throws {
        guard try readRegularFile(url) == expected else {
            throw ChromeProfileError.invalid("The file changed during setup; no newer contents were overwritten: \(url.path).")
        }
    }

    private func createPrivateDirectories(_ url: URL) throws {
        try validateAncestors(url)
        var missing: [URL] = []
        var candidate = url
        while try attributesIfPresent(candidate) == nil {
            missing.append(candidate)
            candidate.deleteLastPathComponent()
        }
        for directory in missing.reversed() {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(url, mustExist: true)
    }

    private func acquireLock() throws -> Int32 {
        let url = supportURL.appendingPathComponent("chrome-profiles.lock")
        _ = try readRegularFileMetadata(url)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ChromeProfileError.invalid("Could not open the profile setup lock.") }
        guard fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw ChromeProfileError.invalid("Another profile setup may already be running. Wait for it to finish.")
        }
        return descriptor
    }

    private func createBackup(_ plan: Plan) throws -> URL {
        let parent = supportURL.appendingPathComponent("Chrome Profile Backups", isDirectory: true)
        try createPrivateDirectories(parent)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = parent.appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        if let data = plan.localStateBefore { try atomicWrite(data, to: backup.appendingPathComponent("Local State")) }
        if let data = plan.manifestBefore { try atomicWrite(data, to: backup.appendingPathComponent("chrome-profiles.json")) }
        try atomicWrite(try jsonData([
            "local_state_existed": plan.localStateBefore != nil,
            "manifest_existed": plan.manifestBefore != nil,
            "created_directories": plan.created.map(\.directory)
        ]), to: backup.appendingPathComponent("backup-info.json"))
        return backup
    }

    /// Same-directory rename is atomic for each file. The journal covers the
    /// multi-file transaction; an interrupted transaction is never auto-adopted.
    private func atomicWrite(_ data: Data, to destination: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        try validateAncestors(destination.deletingLastPathComponent())
        _ = try readRegularFileMetadata(destination)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".workmacsetup-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ChromeProfileError.invalid("Could not stage a private file in \(destination.deletingLastPathComponent().path).") }
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = close(descriptor) }
            _ = unlink(temporary.path)
        }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ChromeProfileError.invalid("Could not write staged profile data.") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ChromeProfileError.invalid("Could not flush staged profile data.") }
        guard close(descriptor) == 0 else { throw ChromeProfileError.invalid("Could not close staged profile data.") }
        descriptorOpen = false
        _ = try readRegularFileMetadata(destination)
        try beforeCommit?()
        guard rename(temporary.path, destination.path) == 0 else {
            throw ChromeProfileError.invalid("Could not atomically replace \(destination.path).")
        }
    }
}
