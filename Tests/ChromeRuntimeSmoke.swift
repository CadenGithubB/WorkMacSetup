import Foundation

// Integration fixture only. Never accepts a production Chrome data directory.
@main
struct ChromeRuntimeSmoke {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, ["prepare", "verify"].contains(args[1]),
              args[2].hasPrefix("/private/tmp/WorkMacSetup-ChromeSmoke.") else {
            throw NSError(domain: "ChromeRuntimeSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use prepare|verify and a mktemp-created /private/tmp/WorkMacSetup-ChromeSmoke.* fixture."])
        }
        let base = URL(fileURLWithPath: args[2], isDirectory: true)
        guard try FileManager.default.attributesOfItem(atPath: base.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw NSError(domain: "ChromeRuntimeSmoke", code: 2)
        }
        let root = base.appendingPathComponent("Chrome", isDirectory: true)
        if args[1] == "prepare" {
            let creator = ChromeProfileCreator(
                rootURL: root,
                supportURL: base.appendingPathComponent("Support", isDirectory: true),
                isChromeRunning: { false }
            )
            _ = try creator.run(clientsTSV: "Example Alpha\tabout:blank\tblue\nExample Beta\tabout:blank\tred\n", dryRun: false)
            print("Prepared two synthetic local profiles at \(root.path)")
        } else {
            let data = try Data(contentsOf: root.appendingPathComponent("Local State"))
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let profile = state["profile"] as! [String: Any]
            let cache = profile["info_cache"] as! [String: [String: Any]]
            for expected in ["Example Alpha", "Example Beta"] {
                guard let entry = cache.first(where: { $0.value["name"] as? String == expected }) else {
                    throw NSError(domain: "ChromeRuntimeSmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Chrome did not retain \(expected) in its profile registry."])
                }
                precondition((entry.value["user_name"] as? String ?? "").isEmpty)
                precondition((entry.value["gaia_id"] as? String ?? "").isEmpty)
                precondition((entry.value["is_consented_primary_account"] as? Bool ?? false) == false)
                let prefsData = try Data(contentsOf: root.appendingPathComponent(entry.key).appendingPathComponent("Preferences"))
                let prefs = try JSONSerialization.jsonObject(with: prefsData) as! [String: Any]
                precondition((prefs["profile"] as? [String: Any])?["name"] as? String == expected)
                precondition((prefs["account_info"] as? [Any] ?? []).isEmpty)
                print("Verified \(expected): registered in \(entry.key), correct name, no linked Google account.")
            }
        }
    }
}
