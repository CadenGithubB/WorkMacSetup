import AppKit
import SwiftUI

// Minimal dependencies let us exercise the real palette without starting
// Work Mac Setup, scanning installed apps, or running any setup actions.
struct InstalledApp: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let icon: NSImage
}

enum InstalledAppScanner {
    static func installedApp(at path: String) -> InstalledApp? { nil }
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

final class SetupRun {
    static var current: SetupRun? { nil }
    func stopForQuit() {}
    func stop() {}
}

@main
struct DragPaletteTests {
    @MainActor
    static func main() throws {
        let dock = DragPaletteStep(rawValue: "dock")!
        precondition(!dock.usesSystemSettings)
        precondition(dock.settingsURL == nil && dock.openButtonTitle == nil && dock.command == nil)
        precondition(DragPaletteStep.loginItems.usesSystemSettings)
        precondition(DragPaletteStep.screenRecording.usesSystemSettings)
        precondition(!DragPaletteStep.windowsApp.usesSystemSettings)

        // The operation contract is independent of the palette's step. Dock,
        // Login Items, and Screen Recording share the same ordinary app drag.
        // This asserts parity, not macOS permission or notification behavior.
        precondition(AppDragView.sourceOperationMask(for: .outsideApplication) == [.copy, .link, .generic])
        precondition(AppDragView.sourceOperationMask(for: .withinApplication).isEmpty)

        // The drag carries a file reference, including paths with URL-significant
        // characters, without moving, launching, or opening the application.
        for path in ["/Applications/Example.app", "/Applications/Example & Co #1.app", "/Applications/Café's App.app"] {
            let item = AppDragView.pasteboardItem(for: path)
            precondition(item.types == [.fileURL])
            let url = URL(string: item.string(forType: .fileURL)!)!
            precondition(url.isFileURL && url.path == path)
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("workmacsetup-step.palette-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let marker = base.appendingPathComponent("done")
        precondition(DragPaletteController.validatedDoneFile(marker.path) != nil)
        precondition(DragPaletteController.validatedDoneFile(base.appendingPathComponent("other").path) == nil)
        precondition(DragPaletteController.validatedDoneFile("/Applications/done") == nil)

        print("Palette routing, drag operations, drag payload, and completion-path tests passed.")

        // Optional AppKit layout checks use synthetic rows only and never
        // perform a drag or load the user's installed apps or preferences.
        if CommandLine.arguments.dropFirst().contains("--layout") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            for count in [0, 3, 20] {
                let apps = (0..<count).map { index in
                    InstalledApp(path: "/Applications/Example \(index + 1).app", name: "Example App \(index + 1)",
                                 icon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!)
                }
                DragPaletteController.shared.show(step: dock, apps: apps, doneFile: marker)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
                let panel = NSApp.windows.compactMap { $0 as? NSPanel }.first!
                let view = panel.contentView!
                view.layoutSubtreeIfNeeded()
                precondition(panel.frame.height < 700, "Long selections must keep Done on screen.")
                precondition(!FileManager.default.fileExists(atPath: marker.path), "Showing the palette must wait for Done.")
                DragPaletteController.shared.close()
                precondition(!FileManager.default.fileExists(atPath: marker.path), "Hiding after Stop must not complete the step.")
            }
            DragPaletteController.shared.show(step: dock, apps: [], doneFile: marker)
            let panel = NSApp.windows.compactMap { $0 as? NSPanel }.first!
            panel.close()
            precondition(FileManager.default.fileExists(atPath: marker.path), "Closing the floating bar must let setup continue.")
            print("Empty, short, and scrolling palette layouts and completion checks passed.")
        }
    }
}
