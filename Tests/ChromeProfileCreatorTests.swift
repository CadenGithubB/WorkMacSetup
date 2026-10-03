import Foundation
import Darwin

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

@main
struct ChromeProfileCreatorTests {
    private static let fm = FileManager.default
    private static var passed = 0

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("200 profiles", { try largeBatch(200) }),
            ("256 profiles", { try largeBatch(256) }),
            ("rerun preserves exact bytes", rerun),
            ("preserve unknown state and existing preferences", preserveExisting),
            ("same-name unowned profile is a conflict", nameConflict),
            ("closed Chrome required before writes", chromeRunning),
            ("Chrome reopening leaves recoverable journal", chromeReopens),
            ("concurrent Local State change is preserved", stateRace),
            ("last-moment Local State change is preserved", finalCommitRace),
            ("another setup lock blocks writes", concurrentSetup),
            ("validate complete batch before writes", invalidInput),
            ("malformed Local State", malformedState),
            ("malformed manifest", malformedManifest),
            ("symlink root", symlinkRoot),
            ("symlink Local State", symlinkState),
            ("symlink profile", symlinkProfile),
            ("symlink manifest", symlinkManifest),
            ("symlink owned Preferences", symlinkPreferences),
            ("dry run writes nothing", dryRun),
            ("local unsigned-in preferences and colors", localProfiles),
            ("pending journal blocks changes", pendingJournal),
            ("backup content and permissions", backupPermissions),
            ("Unicode identity is stable", unicodeIdentity),
            ("invalid metadata fails closed", malformedMetadata),
            ("renamed owned profile refuses stale identity", ownershipMismatch),
            ("pending deletion blocks directory reuse", pendingDeletion),
            ("profile counter is preserved and incremented", profileCounter),
            ("existing profiles flag only names this app did not create", conflictFlags)
        ]
        for (name, test) in tests {
            do { try test(); passed += 1; print("PASS: \(name)") }
            catch { throw TestFailure.failed("\(name): \(error)") }
        }
        print("Passed \(passed) synthetic profile tests. No real Chrome data was used.")
    }

    private static func withFixture(_ test: (URL, URL, URL) throws -> Void) throws {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("WorkMacSetup-ProfileTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        try test(base, base.appendingPathComponent("Chrome"), base.appendingPathComponent("Support"))
    }

    private static func engine(_ root: URL, _ support: URL, running: @escaping () throws -> Bool = { false }) -> ChromeProfileCreator {
        ChromeProfileCreator(rootURL: root, supportURL: support, isChromeRunning: running)
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure.failed(message) }
    }

    private static func expectFailure(containing text: String? = nil, _ body: () throws -> Void) throws {
        do { try body() }
        catch {
            if let text {
                try check(error.localizedDescription.localizedCaseInsensitiveContains(text),
                          "Expected error containing '\(text)', received '\(error.localizedDescription)'")
            }
            return
        }
        throw TestFailure.failed("Expected failure, but operation succeeded")
    }

    private static func write(_ data: Data, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func writeJSON(_ json: [String: Any], _ url: URL) throws {
        try write(JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), url)
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw TestFailure.failed("Expected JSON object at \(url.path)")
        }
        return value
    }

    private static func profileState(_ root: URL) throws -> [String: Any] {
        let state = try json(root.appendingPathComponent("Local State"))
        guard let value = state["profile"] as? [String: Any] else { throw TestFailure.failed("Missing profile metadata") }
        return value
    }

    private static func seedExisting(_ root: URL, name: String = "Personal", directory: String = "Default") throws -> Data {
        let preferences = Data("{\"keep-me\": true, \"account_info\": [{\"fixture\":\"existing-account\"}]}\n".utf8)
        try write(preferences, root.appendingPathComponent(directory).appendingPathComponent("Preferences"))
        try writeJSON([
            "keep": ["boolean": true, "string": "unrelated", "large_integer": UInt64.max],
            "profile": ["last_used": directory, "info_cache": [directory: ["name": name, "existing_field": "untouched"]],
                        "profiles_order": [directory]]
        ], root.appendingPathComponent("Local State"))
        return preferences
    }

    private static func largeBatch(_ count: Int) throws {
        try withFixture { _, root, support in
            let input = (1...count).map { "Client \($0)\thttps://example.test/\($0)\tblue" }.joined(separator: "\n")
            let result = try engine(root, support).run(clientsTSV: input)
            try check(result.created.count == count && result.skipped.isEmpty, "Wrong created count")
            let profile = try profileState(root)
            let cache = profile["info_cache"] as! [String: Any]
            let order = profile["profiles_order"] as! [String]
            try check(cache.count == count && order.count == count, "Missing picker registrations")
            try check(Set(order).count == count, "Duplicate directories")
            for number in 1...count {
                let directory = "Profile \(number)"
                try check(cache[directory] != nil, "Missing \(directory)")
                try check(fm.fileExists(atPath: root.appendingPathComponent(directory).appendingPathComponent("Preferences").path), "Missing profile Preferences")
            }
        }
    }

    private static func rerun() throws {
        try withFixture { base, root, support in
            let creator = engine(root, support)
            _ = try creator.run(clientsTSV: "Acme\thttps://example.test\tblue\nOther\tabout:blank\t")
            let before = try snapshot(base)
            let result = try creator.run(clientsTSV: "Acme\thttps://changed.test\tred\nOther\t\t")
            try check(result.created.isEmpty && result.skipped.count == 2 && result.backupURL == nil, "Rerun should skip existing owned profiles")
            try check(try snapshot(base) == before, "Rerun changed file bytes or created backups")
        }
    }

    private static func preserveExisting() throws {
        try withFixture { _, root, support in
            let original = try seedExisting(root)
            let stateBefore = try json(root.appendingPathComponent("Local State"))
            try fm.createDirectory(at: root.appendingPathComponent("Profile 1"), withIntermediateDirectories: false)
            let result = try engine(root, support).run(clientsTSV: "Acme\t\t")
            try check(result.created.first?.directory == "Profile 2", "Occupied directory was reused")
            let stateAfter = try json(root.appendingPathComponent("Local State"))
            try check(NSDictionary(dictionary: stateBefore["keep"] as! [String: Any]).isEqual(to: stateAfter["keep"] as! [String: Any]), "Unknown Local State data changed")
            let profile = stateAfter["profile"] as! [String: Any]
            try check(profile["last_used"] as? String == "Default", "Last-used profile changed")
            let entry = (profile["info_cache"] as! [String: Any])["Default"] as! [String: Any]
            try check(entry["existing_field"] as? String == "untouched", "Existing registration changed")
            try check(try Data(contentsOf: root.appendingPathComponent("Default/Preferences")) == original, "Existing Preferences changed")
        }
    }

    private static func nameConflict() throws {
        try withFixture { base, root, support in
            _ = try seedExisting(root, name: "ACME")
            let before = try snapshot(base)
            try expectFailure(containing: "not owned") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
            try check(try snapshot(base) == before, "Conflict changed files")
        }
    }

    private static func chromeRunning() throws {
        try withFixture { base, root, support in
            try expectFailure(containing: "Quit Google Chrome") {
                _ = try engine(root, support, running: { true }).run(clientsTSV: "Acme\t\t")
            }
            try check(try fm.contentsOfDirectory(atPath: base.path).isEmpty, "Chrome-open failure wrote files")
        }
    }

    private static func chromeReopens() throws {
        try withFixture { _, root, support in
            var checks = 0
            try expectFailure(containing: "Recovery is required") {
                _ = try engine(root, support, running: { checks += 1; return checks >= 5 }).run(clientsTSV: "Acme\t\t")
            }
            try check(fm.fileExists(atPath: support.appendingPathComponent("chrome-profiles-transaction.json").path), "Missing recovery journal")
            try check(!fm.fileExists(atPath: root.appendingPathComponent("Local State").path), "Registered profiles after Chrome reopened")
            try expectFailure(containing: "unfinished") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
        }
    }

    private static func stateRace() throws {
        try withFixture { _, root, support in
            _ = try seedExisting(root)
            let stateURL = root.appendingPathComponent("Local State")
            let external = Data("{\"external\":\"newer version\"}".utf8)
            var checks = 0
            try expectFailure(containing: "changed during setup") {
                _ = try engine(root, support, running: {
                    checks += 1
                    if checks == 5 { try external.write(to: stateURL) }
                    return false
                }).run(clientsTSV: "Acme\t\t")
            }
            try check(try Data(contentsOf: stateURL) == external, "Overwrote another writer's Local State")
        }
    }

    private static func finalCommitRace() throws {
        try withFixture { _, root, support in
            _ = try seedExisting(root)
            let stateURL = root.appendingPathComponent("Local State")
            let external = Data("{\"external\":\"changed after staging\"}".utf8)
            var checks = 0
            try expectFailure(containing: "changed during setup") {
                _ = try engine(root, support, running: {
                    checks += 1
                    if checks == 8 { try external.write(to: stateURL) }
                    return false
                }).run(clientsTSV: "Acme\t\t")
            }
            try check(try Data(contentsOf: stateURL) == external, "Final staged commit overwrote a newer Local State")
            try check(fm.fileExists(atPath: support.appendingPathComponent("chrome-profiles-transaction.json").path), "Missing journal after final commit conflict")
        }
    }

    private static func concurrentSetup() throws {
        try withFixture { base, root, support in
            try fm.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let lockURL = support.appendingPathComponent("chrome-profiles.lock")
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
            try check(descriptor >= 0, "Cannot prepare fixture lock")
            defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
            try check(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Cannot lock fixture")
            let before = try snapshot(base)
            try expectFailure(containing: "already be running") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
            try check(try snapshot(base) == before, "Competing setup changed files")
        }
    }

    private static func invalidInput() throws {
        for input in ["Valid\t\t\nBad", "Valid\t\t\nValid!\t\t", "Acme\tjavascript:alert(1)\t", "Acme\thttps://\t", "Acme\t\tmauve", "Acme\t\tblue\textra", "\t\t", "", "Acme\thttps://example.test\u{0001}\t"] {
            try withFixture { base, root, support in
                try expectFailure { _ = try engine(root, support).run(clientsTSV: input) }
                try check(try fm.contentsOfDirectory(atPath: base.path).isEmpty, "Invalid input wrote files")
            }
        }
    }

    private static func malformedState() throws {
        try withFixture { base, root, support in
            try write(Data("{not-json}".utf8), root.appendingPathComponent("Local State"))
            let before = try snapshot(base)
            try expectFailure(containing: "valid JSON") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
            try check(try snapshot(base) == before, "Malformed JSON was overwritten")
        }
    }

    private static func malformedManifest() throws {
        try withFixture { base, root, support in
            try writeJSON(["version": 1, "profiles": ["acme": ["name": "Acme", "directory": "../escape"]]], support.appendingPathComponent("chrome-profiles.json"))
            let before = try snapshot(base)
            try expectFailure(containing: "inconsistent") { _ = try engine(root, support).run(clientsTSV: "Other\t\t") }
            try check(try snapshot(base) == before, "Malformed manifest changed files")
        }
    }

    private static func symlinkRoot() throws {
        try withFixture { base, root, support in
            let target = base.appendingPathComponent("actual-root")
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: root, withDestinationURL: target)
            try expectFailure(containing: "symbolic") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
            try check(try fm.contentsOfDirectory(atPath: target.path).isEmpty, "Followed root symlink")
        }
    }

    private static func symlinkState() throws {
        try withFixture { base, root, support in
            let target = base.appendingPathComponent("external-state")
            try write(Data("{}".utf8), target)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: root.appendingPathComponent("Local State"), withDestinationURL: target)
            try expectFailure(containing: "symbolic") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
            try check(try Data(contentsOf: target) == Data("{}".utf8), "Overwrote symlink target")
        }
    }

    private static func symlinkProfile() throws {
        try withFixture { base, root, support in
            let target = base.appendingPathComponent("external-profile")
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try writeJSON([:], root.appendingPathComponent("Local State"))
            try fm.createSymbolicLink(at: root.appendingPathComponent("Profile 1"), withDestinationURL: target)
            try expectFailure(containing: "symbolic") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
        }
    }

    private static func symlinkManifest() throws {
        try withFixture { base, root, support in
            let target = base.appendingPathComponent("external-manifest")
            try writeJSON(["version": 1, "profiles": [:]], target)
            try fm.createDirectory(at: support, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: support.appendingPathComponent("chrome-profiles.json"), withDestinationURL: target)
            try expectFailure(containing: "symbolic") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
        }
    }

    private static func symlinkPreferences() throws {
        try withFixture { base, root, support in
            _ = try engine(root, support).run(clientsTSV: "Acme\t\t")
            let prefs = root.appendingPathComponent("Profile 1/Preferences")
            let target = base.appendingPathComponent("external-preferences")
            try fm.moveItem(at: prefs, to: target)
            try fm.createSymbolicLink(at: prefs, withDestinationURL: target)
            try expectFailure(containing: "symbolic") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
        }
    }

    private static func dryRun() throws {
        try withFixture { base, root, support in
            let result = try engine(root, support).run(clientsTSV: "Acme\t\t", dryRun: true)
            try check(result.created.count == 1 && result.backupURL == nil, "Incorrect dry-run plan")
            try check(try fm.contentsOfDirectory(atPath: base.path).isEmpty, "Dry run wrote files")
            _ = try seedExisting(root)
            let before = try snapshot(base)
            _ = try engine(root, support).run(clientsTSV: "Acme\t\t", dryRun: true)
            try check(try snapshot(base) == before, "Dry run changed existing files")
        }
    }

    private static func localProfiles() throws {
        try withFixture { _, root, support in
            _ = try engine(root, support).run(clientsTSV: "Acme\thttps://example.test\t#4285f4\nBlank\t\t")
            let prefs = try json(root.appendingPathComponent("Profile 1/Preferences"))
            let profile = prefs["profile"] as! [String: Any]
            try check(profile["name"] as? String == "Acme", "Missing visible name")
            try check(profile["using_default_name"] as? Bool == false, "Name is marked default")
            try check(profile["avatar_index"] as? Int == 26, "Incorrect avatar index")
            try check(profile["using_default_avatar"] as? Bool == true, "Missing default-avatar flag")
            try check(prefs["account_info"] == nil && prefs["signin"] == nil && prefs["sync"] == nil, "Created account or Sync preferences")
            let session = prefs["session"] as! [String: Any]
            try check(session["restore_on_startup"] as? Int == 4 && session["startup_urls"] as? [String] == ["https://example.test"], "Wrong startup settings")
            let autogenerated = prefs["autogenerated"] as! [String: Any]
            let theme = autogenerated["theme"] as! [String: Any]
            try check(theme["color"] as? Int == Int(Int32(bitPattern: 0xFF4285F4)), "ARGB color not stored as signed integer")
            let extensions = prefs["extensions"] as! [String: Any]
            try check((extensions["theme"] as! [String: Any])["id"] as? String == "autogenerated_theme_id", "Wrong theme identifier")
            let cache = try profileState(root)["info_cache"] as! [String: Any]
            let entry = cache["Profile 1"] as! [String: Any]
            try check(entry["user_name"] as? String == "" && entry["gaia_id"] as? String == "" && entry["is_consented_primary_account"] as? Bool == false, "Cache has an account or Sync consent")
            let blank = try json(root.appendingPathComponent("Profile 2/Preferences"))
            try check(blank["session"] == nil && blank["extensions"] == nil, "Unrequested startup/theme preferences added")
        }
    }

    private static func pendingJournal() throws {
        try withFixture { base, root, support in
            try writeJSON(["status": "pending"], support.appendingPathComponent("chrome-profiles-transaction.json"))
            let before = try snapshot(base)
            try expectFailure(containing: "unfinished") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
            try check(try snapshot(base) == before, "Pending transaction was altered")
        }
    }

    private static func backupPermissions() throws {
        try withFixture { _, root, support in
            _ = try seedExisting(root)
            let original = try Data(contentsOf: root.appendingPathComponent("Local State"))
            let first = try engine(root, support).run(clientsTSV: "Acme\t\t")
            try check(try Data(contentsOf: first.backupURL!.appendingPathComponent("Local State")) == original, "Backup isn't exact original bytes")
            let previousManifest = try Data(contentsOf: support.appendingPathComponent("chrome-profiles.json"))
            let second = try engine(root, support).run(clientsTSV: "Second\t\t")
            try check(try Data(contentsOf: second.backupURL!.appendingPathComponent("chrome-profiles.json")) == previousManifest, "Manifest wasn't backed up")
            for file in [root.appendingPathComponent("Local State"), root.appendingPathComponent("Profile 1/Preferences"), support.appendingPathComponent("chrome-profiles.json"), first.backupURL!.appendingPathComponent("Local State")] {
                let attrs = try fm.attributesOfItem(atPath: file.path)
                try check((attrs[.posixPermissions] as! NSNumber).intValue == 0o600, "File isn't mode 600")
            }
            for directory in [support, root.appendingPathComponent("Profile 1"), first.backupURL!] {
                let attrs = try fm.attributesOfItem(atPath: directory.path)
                try check((attrs[.posixPermissions] as! NSNumber).intValue == 0o700, "Directory isn't mode 700")
            }
            try check(!fm.fileExists(atPath: support.appendingPathComponent("chrome-profiles-transaction.json").path), "Success retained journal")
        }
    }

    private static func unicodeIdentity() throws {
        try withFixture { _, root, support in
            _ = try engine(root, support).run(clientsTSV: "Café Client\t\t\n顧客\t\t")
            let result = try engine(root, support).run(clientsTSV: "CAFE\u{0301} CLIENT\t\t\n顧客\t\t")
            try check(result.created.isEmpty && result.skipped.count == 2, "Unicode normalization duplicated profiles")
        }
    }

    private static func malformedMetadata() throws {
        let cases: [[String: Any]] = [
            ["profile": "not-an-object"],
            ["profile": ["info_cache": []]],
            ["profile": ["profiles_order": ["Missing"]]],
            ["profile": ["info_cache": ["../escape": ["name": "Bad"]]]]
        ]
        for state in cases {
            try withFixture { base, root, support in
                try writeJSON(state, root.appendingPathComponent("Local State"))
                let before = try snapshot(base)
                try expectFailure { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
                try check(try snapshot(base) == before, "Invalid metadata changed files")
            }
        }
    }

    private static func ownershipMismatch() throws {
        try withFixture { base, root, support in
            _ = try engine(root, support).run(clientsTSV: "Acme\t\t")
            let url = root.appendingPathComponent("Local State")
            var state = try json(url)
            var profile = state["profile"] as! [String: Any]
            var cache = profile["info_cache"] as! [String: Any]
            var entry = cache["Profile 1"] as! [String: Any]
            entry["name"] = "Another Person"
            cache["Profile 1"] = entry
            profile["info_cache"] = cache
            state["profile"] = profile
            try writeJSON(state, url)
            let before = try snapshot(base)
            try expectFailure(containing: "inconsistent") { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
            try check(try snapshot(base) == before, "Stale manifest was adopted")
        }
    }

    private static func pendingDeletion() throws {
        for deletionList: Any in [["Profile 1"], "Profile 1"] {
            try withFixture { base, root, support in
                try writeJSON(["profiles": ["profile_basenames_deleted": deletionList]], root.appendingPathComponent("Local State"))
                let before = try snapshot(base)
                try expectFailure { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
                try check(try snapshot(base) == before, "Created profiles despite pending deletion")
            }
        }
    }

    private static func profileCounter() throws {
        try withFixture { _, root, support in
            try writeJSON(["profile": ["profiles_created": 50]], root.appendingPathComponent("Local State"))
            _ = try engine(root, support).run(clientsTSV: "Acme\t\t\nOther\t\t")
            try check(try profileState(root)["profiles_created"] as? Int == 52, "Did not retain creation counter")
            for invalid: Any in [-1, 1.5, true, "3"] {
                try withFixture { base, root, support in
                    try writeJSON(["profile": ["profiles_created": invalid]], root.appendingPathComponent("Local State"))
                    let before = try snapshot(base)
                    try expectFailure { _ = try engine(root, support).run(clientsTSV: "Acme\t\t") }
                    try check(try snapshot(base) == before, "Invalid profile count changed files")
                }
            }
        }
    }

    private static func conflictFlags() throws {
        try withFixture { base, root, support in
            _ = try seedExisting(root, name: "ACME")
            _ = try engine(root, support).run(clientsTSV: "Beta\t\t")
            let before = try snapshot(base)
            let flagged = engine(root, support).existingProfiles().conflicts(in: ["Acme", "acme!", "Beta", "Gamma"])
            try check(flagged == ["Acme", "acme!"], "Unexpected conflict flags: \(flagged)")
            try check(try snapshot(base) == before, "Conflict check changed files")
        }
    }

    private static func snapshot(_ base: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
        for case let url as URL in enumerator {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let key = String(url.path.dropFirst(base.path.count))
            if attrs[.type] as? FileAttributeType == .typeRegular { result[key] = try Data(contentsOf: url) }
            else if attrs[.type] as? FileAttributeType == .typeDirectory { result[key + "/"] = Data() }
        }
        return result
    }
}
