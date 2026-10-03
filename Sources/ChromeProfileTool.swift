import AppKit
import Foundation
import Darwin

@main
struct ChromeProfileTool {
    static func main() {
        do {
            let clientsFile = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            guard getuid() != 0, geteuid() == getuid() else {
                throw ChromeProfileError.invalid("Run the Chrome profile helper as the signed-in console user, never as root.")
            }
            var console = stat()
            guard stat("/dev/console", &console) == 0, console.st_uid == getuid() else {
                throw ChromeProfileError.invalid("Run the Chrome profile helper as the user currently signed in at the Mac's console.")
            }
            try checkChromePolicies()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let root = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
            let support = home.appendingPathComponent("Library/Application Support/WorkMacSetup", isDirectory: true)
            let clients = try String(contentsOfFile: clientsFile, encoding: .utf8)
            let creator = ChromeProfileCreator(rootURL: root, supportURL: support, isChromeRunning: chromeIsRunning)
            let result = try creator.run(clientsTSV: clients)
            for profile in result.created {
                print("Created local Chrome profile: \(profile.name) (\(profile.directory))")
            }
            for profile in result.skipped {
                print("Already created by Work Mac Setup; left unchanged: \(profile.name) (\(profile.directory))")
            }
            if clients.components(separatedBy: "\n").contains(where: {
                let fields = $0.components(separatedBy: "\t")
                return fields.count >= 2 && !fields[1].isEmpty && fields[1] != "about:blank"
            }) {
                print("Note: Chrome may reset initial startup-page preferences. If needed, set Settings > On startup inside the profile; the app does not bypass Chrome's preference protection.")
            }
            if let backup = result.backupURL { print("Recovery backups: \(backup.path)") }
            print("Open Google Chrome and use its profile picker. These are local profiles; no account was signed in and Sync was not enabled.")
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func parseArguments(_ args: [String]) throws -> String {
        var clientsFile: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--clients-file":
                guard clientsFile == nil, index + 1 < args.count else { throw usageError() }
                clientsFile = args[index + 1]
                index += 2
            default:
                throw usageError()
            }
        }
        guard let clientsFile, !clientsFile.isEmpty else { throw usageError() }
        return clientsFile
    }

    private static func usageError() -> ChromeProfileError {
        .invalid("Usage: chrome-profile-helper --clients-file PATH")
    }

    private static func checkChromePolicies() throws {
        let domain = "com.google.Chrome" as CFString
        func value(_ name: String) -> Any? { CFPreferencesCopyAppValue(name as CFString, domain) }
        func boolean(_ name: String) -> Bool? {
            guard let raw = value(name), CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
            return raw as? Bool
        }
        if boolean("BrowserAddPersonEnabled") == false {
            throw ChromeProfileError.invalid("Your organization's BrowserAddPersonEnabled policy prevents additional Chrome profiles.")
        }
        if let signin = value("BrowserSignin") as? NSNumber, signin.intValue == 2 {
            throw ChromeProfileError.invalid("Your organization's BrowserSignin policy requires sign-in. Work Mac Setup only creates local unsigned-in profiles.")
        }
        if boolean("ForceBrowserSignin") == true {
            throw ChromeProfileError.invalid("Your organization's ForceBrowserSignin policy requires sign-in. Work Mac Setup only creates local unsigned-in profiles.")
        }
        if let configuredRoot = value("UserDataDir") {
            throw ChromeProfileError.invalid("Chrome has a UserDataDir override (\(String(describing: configuredRoot))). Work Mac Setup only supports Chrome's standard data directory.")
        }
    }

    private static func chromeIsRunning() throws -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: {
            guard let identifier = $0.bundleIdentifier else { return false }
            return identifier == "com.google.Chrome" || identifier.hasPrefix("com.google.Chrome.helper")
        }) { return true }

        // NSRunningApplication excludes some background helpers. Inspect fixed
        // executable names as well; no client data is passed to a shell or process.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "uid=,comm="]
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationReason == .exit, task.terminationStatus == 0,
              let listing = String(data: data, encoding: .utf8), !listing.isEmpty else {
            throw ChromeProfileError.invalid("Could not verify that Chrome and its background processes are closed. No profile data was changed.")
        }
        for line in listing.split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, UInt32(fields[0]) == getuid() else { continue }
            let executable = fields[1].trimmingCharacters(in: .whitespaces)
            if executable == "Google Chrome" || executable.hasPrefix("Google Chrome Helper") ||
                executable.hasSuffix("/Google Chrome") ||
                executable.contains("/Google Chrome.app/Contents/") ||
                executable.contains("/Google Chrome Helper") ||
                executable.contains("/Google Chrome Framework.framework/") {
                return true
            }
        }
        return false
    }
}
