import AppKit
import SwiftUI

private struct ClientEntry {
    let name: String
    let startURL: String
    let color: String
}

private enum SetupError: LocalizedError {
    case validation(String)
    case missingResource(String)
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message):
            return message
        case .missingResource(let name):
            return "The app is missing its bundled \(name). Rebuild the app and try again."
        case .couldNotStart(let reason):
            return "Setup could not start: \(reason)"
        }
    }
}

private enum ClientParser {
    static let namedColors = ["blue", "red", "green", "orange", "yellow", "purple", "pink", "teal", "gray"]

    static func parse(_ text: String) throws -> [ClientEntry] {
        var entries: [ClientEntry] = []
        var usedNames = Set<String>()

        for (index, originalLine) in text.components(separatedBy: .newlines).enumerated() {
            var line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            var startURL = "about:blank"
            if let tab = line.firstIndex(of: "\t") {
                startURL = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
                line = String(line[..<tab]).trimmingCharacters(in: .whitespaces)
            } else if let separator = line.range(of: " | ") {
                startURL = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                line = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            guard startURL == "about:blank" || startURL.hasPrefix("https://") || startURL.hasPrefix("http://") else {
                throw SetupError.validation("Line \(index + 1) has an invalid start page. Use https://, http://, or about:blank.")
            }

            var color = ""
            let colorPattern = #"\s-(blue|red|green|orange|yellow|purple|pink|teal|gray|#[0-9A-Fa-f]{6})$"#
            if let range = line.range(of: colorPattern, options: .regularExpression) {
                color = String(line[range]).trimmingCharacters(in: .whitespaces).dropFirst().lowercased()
                line.removeSubrange(range)
                line = line.trimmingCharacters(in: .whitespaces)
            }

            guard !line.isEmpty else {
                throw SetupError.validation("Line \(index + 1) needs a client name.")
            }

            let normalizedName = line.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")

            guard !normalizedName.isEmpty else {
                throw SetupError.validation("Line \(index + 1) needs letters or numbers in its client name.")
            }

            guard usedNames.insert(normalizedName).inserted else {
                throw SetupError.validation("Line \(index + 1) would duplicate another client profile. Make the names more distinct.")
            }

            entries.append(ClientEntry(name: line, startURL: startURL, color: color))
        }

        return entries
    }
}

private struct LabeledEditor: View {
    let title: String
    let help: String
    @Binding var text: String
    var minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollIndicators(.never)
                .scrollContentBackground(.hidden)
                .padding(7)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
                .frame(minHeight: minHeight)
        }
    }
}

struct InstalledApp: Identifiable, Hashable {
    let path: String
    let name: String
    let bundleID: String?
    let icon: NSImage

    var id: String { path }

    // The folder shown beside the name, e.g. "Applications" or "KiCad".
    var folderName: String {
        URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

// Lists installed applications from the standard application folders only.
// These folders are not privacy-protected, so no permission prompt appears.
// Desktop, Documents, Downloads, and other protected locations are never read.
enum InstalledAppScanner {
    static var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    static func isApplication(at url: URL) -> Bool {
        url.pathExtension == "app" && isDirectory(url)
    }

    // Accepts only installed apps inside the scanned folders (one vendor folder
    // deep), so a path received from outside the app can never point the app at
    // a privacy-protected location.
    static func isTrustedApplicationPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard isApplication(at: url) else { return false }
        let parent = url.deletingLastPathComponent()
        let grandparent = parent.deletingLastPathComponent()
        return roots.contains { root in
            let root = root.standardizedFileURL
            return parent == root || (grandparent == root && parent.pathExtension != "app")
        }
    }

    static func installedApp(at path: String) -> InstalledApp? {
        guard isTrustedApplicationPath(path) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return InstalledApp(
            path: url.path,
            name: FileManager.default.displayName(atPath: url.path),
            bundleID: Bundle(url: url)?.bundleIdentifier,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func entries(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        )) ?? []
    }

    static func scan() -> [InstalledApp] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        func add(_ url: URL) {
            let bundleID = Bundle(url: url)?.bundleIdentifier
            // Dedupe by bundle ID; an app without one is identified by its path.
            guard seen.insert(bundleID ?? url.path).inserted else { return }
            apps.append(InstalledApp(
                path: url.path,
                name: fileManager.displayName(atPath: url.path),
                bundleID: bundleID,
                icon: NSWorkspace.shared.icon(forFile: url.path)
            ))
        }

        for root in roots {
            for entry in entries(of: root) where isDirectory(entry) {
                if isApplication(at: entry) {
                    add(entry)
                } else {
                    // One level of vendor folders such as /Applications/Microsoft Office.
                    // Never descend into .app bundles.
                    for nested in entries(of: entry) where isApplication(at: nested) {
                        add(nested)
                    }
                }
            }
        }

        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct InstalledAppChecklist: View {
    let title: String
    let help: String
    let apps: [InstalledApp]
    let isScanning: Bool
    let selectedPaths: Set<String>
    let toggle: (InstalledApp, Bool) -> Void

    @State private var search = ""

    private var filteredApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search installed apps", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search installed apps")

            Group {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding installed apps…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else if filteredApps.isEmpty {
                    Text(apps.isEmpty ? "No applications were found in the standard application folders." : "No installed apps match your search.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredApps) { app in
                                Toggle(isOn: Binding(
                                    get: { selectedPaths.contains(app.path) },
                                    set: { toggle(app, $0) }
                                )) {
                                    HStack(spacing: 8) {
                                        Image(nsImage: app.icon)
                                            .resizable()
                                            .frame(width: 20, height: 20)
                                        Text(app.name)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(app.folderName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .help(app.path)
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }
        }
    }
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("setWindowsCredSSP") private var setWindowsCredSSP = true
    // Keep the stored key so existing users retain their action selection.
    @AppStorage("createChromeLaunchers") private var createChromeProfiles = true
    // New key so the step is off by default, even for users who ran older builds.
    @AppStorage("openScreenRecordingSettings") private var openPrivacySettings = false
    // New key so the step is off by default, even where a test build saved it on.
    @AppStorage("openLoginItemsStep") private var openLoginItemsSettings = false
    // Newline-separated .app paths the user wants to add under Open at Login.
    @AppStorage("loginItemApps") private var loginItemApps = ""
    // Newline-separated .app paths to allow under Screen & System Audio Recording.
    @AppStorage("screenRecordingApps") private var screenRecordingApps = ""

    // Intentionally not persisted. Client names live only in memory and in a
    // permission-restricted temporary file while the setup command is running.
    @State private var clientLines = ""
    @State private var alertMessage = ""
    @State private var showingAlert = false
    @State private var showingLoginItems = false
    @State private var showingScreenRecordingApps = false
    @State private var activeRun: SetupRun?
    // Chrome's existing profile names, to flag clients that would clash.
    @State private var chromeProfiles = ChromeExistingProfiles.none
    @State private var installedApps: [InstalledApp] = []
    @State private var isScanningApps = false

    private func storedPaths(_ stored: String) -> [String] {
        stored.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // Apps that were removed since they were selected are ignored quietly.
    private func installedPaths(_ stored: String) -> [String] {
        storedPaths(stored).filter { InstalledAppScanner.isApplication(at: URL(fileURLWithPath: $0)) }
    }

    private var selectedLoginItemPaths: [String] { installedPaths(loginItemApps) }
    private var selectedScreenRecordingPaths: [String] { installedPaths(screenRecordingApps) }

    private var parsedClients: Result<[ClientEntry], Error> {
        Result { try ClientParser.parse(clientLines) }
    }

    // Client names that are already Chrome profiles this app did not create.
    private var conflictingClients: [String] {
        guard createChromeProfiles, case .success(let clients) = parsedClients else { return [] }
        return chromeProfiles.conflicts(in: clients.map(\.name))
    }

    private var clientSummary: String {
        switch parsedClients {
        case .success(let clients):
            if !conflictingClients.isEmpty { return Self.conflictMessage(conflictingClients) }
            return clients.isEmpty ? "No clients entered" : "\(clients.count) client profile\(clients.count == 1 ? "" : "s") ready"
        case .failure(let error):
            return error.localizedDescription
        }
    }

    private var canRun: Bool {
        if !createChromeProfiles { return true }
        switch parsedClients {
        case .success(let clients):
            return !clients.isEmpty && conflictingClients.isEmpty
        case .failure:
            return false
        }
    }

    private static func conflictMessage(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        let list = quoted.count == 1 ? quoted[0] : quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
        if names.count == 1 {
            return "\(list) is already a Chrome profile this app didn't create. Rename or remove it; the existing profile stays as it is."
        }
        return "\(list) are already Chrome profiles this app didn't create. Rename or remove them; the existing profiles stay as they are."
    }

    // Reads the same Chrome data the profile helper uses, without changing it.
    private static func readChromeProfiles() -> ChromeExistingProfiles {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ChromeProfileCreator(
            rootURL: home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true),
            supportURL: home.appendingPathComponent("Library/Application Support/WorkMacSetup", isDirectory: true),
            isChromeRunning: { false }
        ).existingProfiles()
    }

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "laptopcomputer.and.arrow.down")
                        .font(.system(size: 38))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Work Mac Setup")
                            .font(.largeTitle.bold())
                        Text("Create client Chrome profiles, then select login items and screen recording permissions")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        openWindow(id: "guide")
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 22))
                            Text("Instructions")
                                .font(.body)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open instructions")
                    .accessibilityLabel("Open instructions")
                }

                GroupBox("1. Client Chrome profiles") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledEditor(
                            title: "Client list",
                            help: "One client per line; profiles appear in Chrome's picker. Example: Acme -blue | https://portal.example.com",
                            text: $clientLines,
                            minHeight: 340
                        )

                        HStack(alignment: .top) {
                            Label(clientSummary, systemImage: canRun ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(canRun ? .green : .orange)
                            Spacer()
                            Text("Colors: blue, red, green, orange, yellow, purple, pink, teal, gray, or #RRGGBB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(.top, 6)
                }

                HStack(alignment: .bottom, spacing: 18) {
                    GroupBox("2. Actions") {
                        VStack(alignment: .leading, spacing: 9) {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("Create Chrome profiles", isOn: $createChromeProfiles)
                                Text("Quit Chrome first. New profiles are local, with no Google account or Sync.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 20)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("Set Windows App EnforceCredSSPSupport to 0", isOn: $setWindowsCredSSP)
                                Text("Shows a command to paste into Terminal; this app never changes Windows App's settings itself.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 20)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Open Login Items settings to add selected apps", isOn: Binding(
                                    get: { openLoginItemsSettings },
                                    set: { enabled in
                                        openLoginItemsSettings = enabled
                                        // The app list stays collapsed until it is expanded by hand.
                                        showingLoginItems = false
                                    }
                                ))

                                if openLoginItemsSettings {
                                    DisclosureGroup(isExpanded: $showingLoginItems) {
                                        InstalledAppChecklist(
                                            title: "Apps to add at login",
                                            help: "Setup opens System Settings > General > Login Items and shows a small floating window with these apps. Drag each one into the Open at Login list yourself; the app never changes login items, so no extra permission is needed.",
                                            apps: installedApps,
                                            isScanning: isScanningApps,
                                            selectedPaths: Set(selectedLoginItemPaths),
                                            toggle: { app, selected in loginItemApps = updatedSelection(loginItemApps, app: app, selected: selected) }
                                        )
                                        .padding(.top, 6)
                                        .task { scanInstalledAppsIfNeeded() }
                                    } label: {
                                        DisclosureLabel(title: "Apps to add (\(selectedLoginItemPaths.count))", isExpanded: $showingLoginItems)
                                    }
                                    .padding(.leading, 20)
                                }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Open Screen & System Audio Recording settings", isOn: Binding(
                                    get: { openPrivacySettings },
                                    set: { enabled in
                                        openPrivacySettings = enabled
                                        showingScreenRecordingApps = false
                                    }
                                ))

                                if openPrivacySettings {
                                    DisclosureGroup(isExpanded: $showingScreenRecordingApps) {
                                        InstalledAppChecklist(
                                            title: "Apps to allow screen recording",
                                            help: "Setup opens Privacy & Security > Screen & System Audio Recording and shows a small floating window with these apps. Drag each one into the list and turn on its switch yourself; the app never grants the permission.",
                                            apps: installedApps,
                                            isScanning: isScanningApps,
                                            selectedPaths: Set(selectedScreenRecordingPaths),
                                            toggle: { app, selected in screenRecordingApps = updatedSelection(screenRecordingApps, app: app, selected: selected) }
                                        )
                                        .padding(.top, 6)
                                        .task { scanInstalledAppsIfNeeded() }
                                    } label: {
                                        DisclosureLabel(title: "Apps to allow (\(selectedScreenRecordingPaths.count))", isExpanded: $showingScreenRecordingApps)
                                    }
                                    .padding(.leading, 20)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Spacer(minLength: 12)

                    HStack {
                        Button("Run Setup") {
                            perform { try launchSetup() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRun)
                    }
                    .fixedSize()
                }
                .id("actions")

            }
            .padding(24)
            // Expanding an editor adds content below the fold; bring it and the
            // Run buttons into view so it is clear the window has grown.
            .onChange(of: showingLoginItems) { expanded in if expanded { revealActions(proxy) } }
            .onChange(of: showingScreenRecordingApps) { expanded in if expanded { revealActions(proxy) } }
            }
        }
        .frame(minWidth: 760, minHeight: 720)
        .background(MainWindowSizing())
        // Chrome's profiles can change while the app is in the background.
        .onAppear { chromeProfiles = Self.readChromeProfiles() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            chromeProfiles = Self.readChromeProfiles()
        }
        .alert("Work Mac Setup", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .sheet(item: $activeRun) { run in
            SetupRunSheet(
                run: run,
                stop: {
                    run.stop()
                    DragPaletteController.shared.close()
                },
                dismiss: {
                    activeRun = nil
                    chromeProfiles = Self.readChromeProfiles()
                }
            )
        }
    }

    private func revealActions(_ proxy: ScrollViewProxy) {
        // Let the disclosure finish laying out its content before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("actions", anchor: .bottom)
            }
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    private func updatedSelection(_ stored: String, app: InstalledApp, selected: Bool) -> String {
        var paths = storedPaths(stored).filter { $0 != app.path }
        if selected { paths.append(app.path) }
        return paths.joined(separator: "\n")
    }

    private func scanInstalledAppsIfNeeded() {
        guard installedApps.isEmpty, !isScanningApps else { return }
        isScanningApps = true
        // Reading the application folders needs no permission, but keep the
        // bundle reads and icon lookups off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = InstalledAppScanner.scan()
            DispatchQueue.main.async {
                installedApps = apps
                isScanningApps = false
            }
        }
    }

    private func resource(named name: String) throws -> URL {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else {
            throw SetupError.missingResource(name)
        }
        return url
    }

    private func launchSetup() throws {
        let clients = createChromeProfiles ? try ClientParser.parse(clientLines) : []
        if createChromeProfiles && clients.isEmpty {
            throw SetupError.validation("Enter at least one client, or turn off Chrome profile creation.")
        }
        let script = try resource(named: "post-enrollment.sh")
        if createChromeProfiles {
            _ = try resource(named: "chrome-profile-helper")
            // Check again right before running, in case Chrome changed since.
            chromeProfiles = Self.readChromeProfiles()
            let conflicts = chromeProfiles.conflicts(in: clients.map(\.name))
            if !conflicts.isEmpty {
                throw SetupError.validation(Self.conflictMessage(conflicts))
            }
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").contains(where: { !$0.isTerminated }) {
                throw SetupError.validation("Quit Google Chrome with Command-Q before creating profiles. The app will not close Chrome or modify open profiles for you.")
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkMacSetup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let clientsURL = directory.appendingPathComponent("clients.tsv")
        let configURL = directory.appendingPathComponent("setup.conf")
        let statusURL = directory.appendingPathComponent("status.tsv")

        let clientTSV = clients.map { entry in
            "\(entry.name)\t\(entry.startURL)\t\(entry.color)"
        }.joined(separator: "\n") + (clients.isEmpty ? "" : "\n")

        let loginItemPaths = openLoginItemsSettings ? selectedLoginItemPaths : []
        let loginItemValues = loginItemPaths.map(shellQuote).joined(separator: " ")
        let screenRecordingPaths = openPrivacySettings ? selectedScreenRecordingPaths : []
        let screenRecordingValues = screenRecordingPaths.map(shellQuote).joined(separator: " ")
        let config = """
        CLIENTS_FILE=\(shellQuote(clientsURL.path))
        STATUS_FILE=\(shellQuote(statusURL.path))
        SET_WINDOWS_CREDSSP=\(setWindowsCredSSP ? 1 : 0)
        CREATE_CHROME_PROFILES=\(createChromeProfiles ? 1 : 0)
        OPEN_SCREEN_RECORDING_SETTINGS=\(openPrivacySettings ? 1 : 0)
        SCREEN_RECORDING_APPS=(\(screenRecordingValues))
        OPEN_LOGIN_ITEMS_SETTINGS=\(openLoginItemsSettings ? 1 : 0)
        LOGIN_ITEM_APPS=(\(loginItemValues))
        CHROME_APP_PATH="/Applications/Google Chrome.app"
        """

        try writePrivate(clientTSV, to: clientsURL, permissions: 0o600)
        try writePrivate(config + "\n", to: configURL, permissions: 0o600)
        try writePrivate("", to: statusURL, permissions: 0o600)

        // The selected steps, in the order the script runs them. The ids match
        // the step names the script records in the status file.
        var steps: [SetupStep] = []
        if createChromeProfiles { steps.append(SetupStep(id: "chrome-profiles", title: "Chrome profiles for \(clients.count) client\(clients.count == 1 ? "" : "s")")) }
        if openLoginItemsSettings { steps.append(SetupStep(id: "login-items", title: "Login items")) }
        if openPrivacySettings { steps.append(SetupStep(id: "screen-recording", title: "Screen recording permissions")) }
        if setWindowsCredSSP { steps.append(SetupStep(id: "windows-app", title: "Windows App CredSSP setting")) }

        // Setup runs inside the app; its progress and output appear in the result window.
        let run = SetupRun(steps: steps, workDirectory: directory, statusFile: statusURL)
        do {
            try run.start(script: script, config: configURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw SetupError.couldNotStart(error.localizedDescription)
        }
        activeRun = run
    }

    private func writePrivate(_ contents: String, to url: URL, permissions: Int) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// SwiftUI's defaultSize can be overridden by an older saved window frame.
// Apply the comfortable starting size once per main window, then allow normal
// manual resizing. Keep the window inside the available display area.
private struct MainWindowSizing: NSViewRepresentable {
    static let preferredContentSize = NSSize(width: 860, height: 800)

    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ nsView: SizingView, context: Context) {}

    final class SizingView: NSView {
        private var hasSizedWindow = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !hasSizedWindow else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, !self.hasSizedWindow else { return }
                self.hasSizedWindow = true

                let current = window.frame
                let preferred = window.frameRect(forContentRect: NSRect(
                    origin: .zero, size: MainWindowSizing.preferredContentSize
                ))
                var frame = current
                frame.size.width = max(current.width, preferred.width)
                // Also shrink an oversized frame restored from an older build.
                frame.size.height = preferred.height

                if let screen = window.screen ?? NSScreen.main {
                    let available = screen.visibleFrame
                    frame.size.width = min(frame.width, available.width)
                    frame.size.height = min(frame.height, available.height)
                    frame.origin.x = max(available.minX, min(current.minX, available.maxX - frame.width))
                    frame.origin.y = max(available.minY, min(current.maxY - frame.height, available.maxY - frame.height))
                }
                window.setFrame(frame, display: true)
            }
        }
    }
}

// Help > Work Mac Setup Help opens the built-in guide window instead of
// asking macOS for a help book the app does not have.
private struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Work Mac Setup Help") {
                openWindow(id: "guide")
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

@main
struct WorkMacSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: MainWindowSizing.preferredContentSize.width, height: MainWindowSizing.preferredContentSize.height)
        // workmacsetup:// URLs are handled by AppDelegate; never open extra main windows for them.
        .handlesExternalEvents(matching: [])
        .commands {
            HelpCommands()
        }

        Window("Work Mac Setup Guide", id: "guide") {
            GuideView()
        }
        .defaultSize(width: 860, height: GuideView.initialContentHeight)
        .windowResizability(.contentMinSize)
        // Otherwise SwiftUI routes workmacsetup:// URLs here and opens the guide.
        .handlesExternalEvents(matching: [])
    }
}
