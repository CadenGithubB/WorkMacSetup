import AppKit
import SwiftUI

// This process owns only the Dock drag panel. Its signed sandbox permits
// reading standard Applications folders, but not modifying installed apps.
@main
struct DockDragHelper {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var args = Array(CommandLine.arguments.dropFirst())
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        while !args.isEmpty {
            let option = args.removeFirst()
            guard !args.isEmpty else { exit(2) }
            let value = args.removeFirst()
            switch option {
            case "--app":
                guard let app = InstalledAppScanner.installedApp(at: value) else { exit(3) }
                if seen.insert(app.path).inserted { apps.append(app) }
            case "--dock-edge":
                guard ["bottom", "left", "right"].contains(value) else { exit(2) }
                DragPaletteController.shared.dockEdgeOverride = value
            case "--anchor":
                let frame = NSRectFromString(value)
                guard frame.width > 0, frame.height > 0,
                      [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { exit(2) }
                DragPaletteController.shared.dockAnchorOverride = frame
            default:
                exit(2)
            }
        }
        DragPaletteController.shared.show(step: .dock, apps: apps, onCompletion: { NSApp.terminate(nil) })
        NSApp.run()
    }
}
