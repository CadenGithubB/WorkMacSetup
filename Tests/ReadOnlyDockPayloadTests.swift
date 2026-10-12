import AppKit
import os

// Compile with DOCK_DRAG_HELPER and the helper's signed entitlements. This
// opt-in integration test exports one explicitly provided app reference on
// private pasteboards only; it never changes the Dock or the selected app.
@main struct ReadOnlyDockPayloadTests {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2,
              let app = InstalledAppScanner.installedApp(at: CommandLine.arguments[1]) else {
            fputs("Provide one installed app path from the standard application folders.\n", stderr)
            exit(2)
        }
        let logger = Logger(subsystem: "local.workmacsetup.readonlypayloadtests", category: "test")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        precondition(AppDragView.sourceOperationMask(for: .outsideApplication) == [.copy, .link, .generic])
        for attempt in 1...2 {
            logger.notice("BEGIN payload attempt=\(attempt)")
            let board = NSPasteboard.withUniqueName()
            let item = AppDragView.pasteboardItem(for: app.path)
            precondition(item.types == [.fileURL])
            precondition(board.writeObjects([item]))
            precondition(URL(string: board.string(forType: .fileURL)!)?.path == app.path)
            board.releaseGlobally()
            logger.notice("END payload attempt=\(attempt) success=true")
        }
        print("Read-only production scanner, file-URL payload, and shared drag contract passed.")
    }
}
