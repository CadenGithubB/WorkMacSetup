import Foundation

@main
struct GuideDocumentTests {
    static func main() throws {
        let withSummary = GuideDocument.parse("""
        ## Example

        Introductory text.

        ### First card

        Card text.
        """)
        precondition(withSummary.count == 1)
        precondition(withSummary[0].summary == "Introductory text.")
        precondition(withSummary[0].groups.first?.title == "First card")

        let withoutSummary = GuideDocument.parse("""
        ## Example

        ### First card

        Card text.
        """)
        precondition(withoutSummary.count == 1)
        precondition(withoutSummary[0].summary.isEmpty)
        precondition(withoutSummary[0].groups.first?.title == "First card")
        guard case .paragraph("Card text.") = withoutSummary[0].groups.first?.blocks.first else {
            fatalError("A topic without an introduction must keep its first card intact.")
        }

        let guide = try String(contentsOfFile: "GUIDE.md", encoding: .utf8)
        let topics = GuideDocument.parse(guide)
        precondition(topics.count == 9)
        precondition(!guide.contains("Jamf"))
        precondition(!guide.lowercased().contains("dry run") && !guide.contains("--dry-run"))
        precondition(!topics.contains { $0.title == "Erase & re-enroll" })
        precondition(topics.map(\.id) == Array(0..<topics.count))
        let dockApps = topics.first { $0.title == "Dock apps" }!
        precondition(dockApps.symbol == "square.grid.2x2")
        precondition(!dockApps.summary.isEmpty)
        let loginItems = topics.first { $0.title == "Login items" }!
        precondition(loginItems.symbol == "checklist")
        precondition(!loginItems.summary.isEmpty)
        precondition(loginItems.groups.map(\.title) == ["Pick the apps", "Drag them into Open at Login"])
        let loginSteps = loginItems.groups.last!.blocks.filter { if case .step = $0 { return true }; return false }
        precondition(loginSteps.count == 4)
        precondition(loginItems.groups.last!.blocks.contains {
            if case .callout(let text) = $0 { return text.contains("does not try") }
            return false
        })
        precondition(topics.firstIndex { $0.title == "Run setup" }! < topics.firstIndex { $0.title == "Dock apps" }!)
        precondition(topics.firstIndex { $0.title == "Dock apps" }! < topics.firstIndex { $0.title == "Login items" }!)
        precondition(topics.firstIndex { $0.title == "Login items" }! < topics.firstIndex { $0.title == "Permissions & privacy" }!)
        let privacy = topics.first { $0.title == "Permissions & privacy" }!
        precondition(privacy.summary.isEmpty)
        precondition(privacy.groups.first!.blocks.contains {
            if case .paragraph(let text) = $0 { return text.contains("Allow Screen Recording") }
            return false
        })
        precondition(privacy.groups.map(\.title) == [
            "Screen and audio access", "What stays on this Mac", "Chrome compatibility"
        ])
        let troubleshooting = topics.first { $0.title == "Troubleshooting" }!
        precondition(troubleshooting.groups.map(\.title) == [
            "Run Setup is greyed out",
            "Chrome is reported as still running",
            "A client name already exists",
            "Nothing changed after a run",
            "Chrome is not installed",
            "A management policy blocks profile creation",
            "Setup says recovery is required"
        ])
        precondition(troubleshooting.groups.allSatisfy { !$0.blocks.isEmpty })
        let recovery = troubleshooting.groups.last!
        let steps = recovery.blocks.filter { if case .step = $0 { return true }; return false }
        precondition(steps.count == 3)
        precondition(recovery.blocks.contains {
            if case .callout(let text) = $0 { return text.contains("Do not delete the journal") }
            return false
        })
        precondition(!guide.contains("Desktop-folder access"))
        precondition(!guide.contains("Older isolated"))
        precondition(!guide.contains("Chrome for Testing"))
        print("Guide document tests passed.")
    }
}
