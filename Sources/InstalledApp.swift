import AppKit

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
        #if DOCK_DRAG_HELPER
        // App Sandbox redirects the default home to its container. The named
        // user's Applications folder is covered by a read-only entitlement.
        let home = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory(), isDirectory: true)
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        #endif
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
