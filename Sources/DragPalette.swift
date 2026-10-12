import AppKit
import SwiftUI

#if !DOCK_DRAG_HELPER
// Handles workmacsetup://drag-palette URLs sent by post-enrollment.sh when it
// reaches a guided setup step. The URL only names the step and the
// installed apps to show in a floating drag palette; nothing is launched and
// no setting is changed by the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DragPaletteController.shared.handle(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockDragRunner.shared.cancel()
        SetupRun.current?.stopForQuit()
    }
}
#endif

// The guided steps that use the floating palette. Raw values match the script.
enum DragPaletteStep: String {
    case dock = "dock"
    case loginItems = "login-items"
    case screenRecording = "screen-recording"
    case windowsApp = "windows-app"

    /// Windows App keeps its settings in its own sandbox, and macOS asks before
    /// another app writes there. The user runs this in Terminal instead.
    static let windowsAppCommand = "defaults write com.microsoft.rdc.macos ClientSettings.EnforceCredSSPSupport 0"

    var windowTitle: String {
        switch self {
        case .dock: return "Drag into the Dock"
        case .loginItems: return "Drag into Open at Login"
        case .screenRecording: return "Allow Screen Recording"
        case .windowsApp: return "Windows App setting"
        }
    }

    var heading: String {
        switch self {
        case .dock: return "Add these apps to the Dock"
        case .loginItems: return "Add these apps to Open at Login"
        case .screenRecording: return "Allow these apps to record the screen"
        case .windowsApp: return "Run this command in Terminal"
        }
    }

    var symbol: String {
        self == .windowsApp ? "terminal" : "hand.draw"
    }

    /// The command to copy, for a step the user finishes in Terminal.
    var command: String? {
        self == .windowsApp ? Self.windowsAppCommand : nil
    }

    /// Steps shown beside System Settings; the others sit beside this app.
    var usesSystemSettings: Bool {
        self == .loginItems || self == .screenRecording
    }

    var dragDestination: String {
        switch self {
        case .dock: return "the Dock"
        case .loginItems: return "Open at Login"
        case .screenRecording: return "Screen & System Audio Recording"
        case .windowsApp: return "Terminal"
        }
    }

    var instructions: String {
        switch self {
        case .dock:
            return "Drag each app below onto the apps side of the Dock, placing it where you want it. Click Done when you are finished."
        case .loginItems:
            return "In System Settings > General > Login Items, drag each app below into the Open at Login list. When they all appear there, click Done to continue setup."
        case .screenRecording:
            return "In System Settings > Privacy & Security > Screen & System Audio Recording, drag each app below into the list and turn on its switch. Then click Done to continue setup."
        case .windowsApp:
            return "Open Terminal, paste this command, and press Return. If Terminal asks to access data from other apps, click Allow. Then click Done to continue setup."
        }
    }

    var emptyText: String {
        switch self {
        case .dock:
            return "No apps were selected. You can drag apps from Finder into the Dock, or click Done to continue."
        case .loginItems:
            return "No apps were selected. Use the + button under Open at Login to add any you need, then click Done."
        case .screenRecording:
            return "No apps were selected. Use the + button in Screen & System Audio Recording to add any you need, turn on their switches, then click Done."
        case .windowsApp:
            return ""
        }
    }

    var tip: String {
        switch self {
        case .dock:
            return "Drop to the left of the divider in a bottom Dock, or above it in a side Dock. If the Dock is hidden, move the pointer to its edge of the screen."
        case .loginItems:
            return "Tip: if dragging does not work, click + in System Settings and choose the app."
        case .screenRecording:
            return "Tip: if dragging does not work, click + and choose the app. macOS may ask you to quit and reopen the app."
        case .windowsApp:
            return ""
        }
    }

    var openButtonTitle: String? {
        switch self {
        case .dock: return nil
        case .loginItems: return "Open Login Items"
        case .screenRecording: return "Open Screen Recording"
        case .windowsApp: return nil
        }
    }

    var settingsURL: URL? {
        switch self {
        case .dock:
            return nil
        case .loginItems:
            return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .windowsApp:
            return nil
        }
    }
}

@MainActor
final class DragPaletteController {
    static let shared = DragPaletteController()

    private var panel: NSPanel?
    private var positioningToken = 0
    private var currentDoneFile: URL?
    private var quitsSettingsOnFinish = false
    private var currentStep: DragPaletteStep?
    private var completion: (() -> Void)?
    var dockEdgeOverride: String?
    var dockAnchorOverride: NSRect?

    #if !DOCK_DRAG_HELPER
    private func showReadOnlyDock(apps: [InstalledApp], doneFile: URL?) {
        close()
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/Work Mac Dock Helper.app/Contents/MacOS/WorkMacDockHelper")
        var arguments = apps.flatMap { ["--app", $0.path] }
        let edge = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
        arguments += ["--dock-edge", edge]
        if let frame = appWindowFrame() {
            arguments += ["--anchor", NSStringFromRect(frame)]
        }
        // Only the parent can write the step marker. The helper receives no
        // config/client data or write access to installed applications.
        let complete: (Int32) -> Void = { status in
            let message = status == 0 ? "" : "error: The read-only Dock window could not complete (exit \(status))."
            if let doneFile {
                do {
                    // Publish contents and existence together; the shell must
                    // never mistake a partially written error for success.
                    try Data(message.utf8).write(to: doneFile, options: .atomic)
                } catch {
                    SetupRun.current?.stop()
                    let alert = NSAlert()
                    alert.messageText = "Could not report the Dock result"
                    alert.informativeText = "Setup was stopped because its temporary completion file could not be written. Reopen Work Mac Setup and try again."
                    alert.runModal()
                    return
                }
            }
            if status != 0 {
                let alert = NSAlert()
                alert.messageText = "The Dock window could not complete"
                alert.informativeText = "Reopen Work Mac Setup and try again. No application-management permission is needed."
                alert.runModal()
            }
        }
        do {
            try DockDragRunner.shared.start(executable: executable, arguments: arguments, onFinish: complete)
        } catch {
            complete(1)
        }
    }
    #endif

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "workmacsetup", url.host?.lowercased() == "drag-palette" else { return }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.path == "/close" {
            if queryItems.contains(where: { $0.name == "settings" && $0.value == "quit" }) {
                quitSystemSettings()
            }
            close()
            return
        }
        guard let stepValue = queryItems.first(where: { $0.name == "step" })?.value,
              let step = DragPaletteStep(rawValue: stepValue) else { return }
        let apps = queryItems
            .filter { $0.name == "app" }
            .compactMap { $0.value }
            .compactMap(InstalledAppScanner.installedApp(at:))
        var seen = Set<String>()
        let doneFile = queryItems.first { $0.name == "done" }?.value.flatMap(Self.validatedDoneFile(_:))
        let isLastStep = queryItems.contains { $0.name == "last" && $0.value == "1" }
        let uniqueApps = apps.filter { seen.insert($0.path).inserted }
        #if !DOCK_DRAG_HELPER
        if step == .dock {
            showReadOnlyDock(apps: uniqueApps, doneFile: doneFile)
            return
        }
        #endif
        show(step: step, apps: uniqueApps, doneFile: doneFile, quitsSettings: isLastStep)
    }

    // The script waits for this empty marker file so that Done in the palette
    // continues setup without a trip back to Terminal. Only accept a file named
    // "done" inside an existing "workmacsetup-step.*" temporary folder, so a
    // stray URL can never make the app write anywhere else.
    static func validatedDoneFile(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let folder = url.deletingLastPathComponent()
        // Foundation drops the "/private" prefix when resolving, so compare without it.
        var resolvedFolder = folder.resolvingSymlinksInPath().path
        if resolvedFolder.hasPrefix("/private/") { resolvedFolder.removeFirst("/private".count) }
        guard url.lastPathComponent == "done",
              folder.lastPathComponent.hasPrefix("workmacsetup-step."),
              resolvedFolder.hasPrefix("/var/folders/") || resolvedFolder.hasPrefix("/tmp/"),
              InstalledAppScanner.isDirectory(folder) else { return nil }
        return url
    }

    func show(step: DragPaletteStep, apps: [InstalledApp], doneFile: URL? = nil, quitsSettings: Bool = false, onCompletion: (() -> Void)? = nil) {
        #if !DOCK_DRAG_HELPER
        DockDragRunner.shared.cancel()
        #endif
        currentDoneFile = doneFile
        completion = onCompletion
        quitsSettingsOnFinish = quitsSettings && step.usesSystemSettings
        currentStep = step
        let content = DragPaletteView(
            step: step,
            apps: apps,
            openSettings: {
                if let url = step.settingsURL { NSWorkspace.shared.open(url) }
            },
            done: { [weak self] in
                self?.finishStep()
                self?.close()
            }
        )
        let hosting = NSHostingView(rootView: content)

        let panel = self.panel ?? makePanel()
        panel.title = step.windowTitle
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.panel = panel
        positioningToken += 1
        placeAndReveal(panel, token: positioningToken, attempt: 0)
    }

    // Done, or closing the palette with its close button, tells the script to
    // continue. The script's own close request (orderOut) does not count.
    private func finishStep() {
        if let callback = completion {
            completion = nil
            callback()
            return
        }
        guard let doneFile = currentDoneFile else { return }
        currentDoneFile = nil
        FileManager.default.createFile(atPath: doneFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        if quitsSettingsOnFinish {
            quitsSettingsOnFinish = false
            quitSystemSettings()
        }
    }

    // After the last guided step, close System Settings so the user is back
    // at the Terminal window that is narrating setup. This asks the app to
    // quit normally; it needs no Automation permission.
    private func quitSystemSettings() {
        for settings in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences") {
            settings.terminate()
        }
    }

    func close() {
        #if !DOCK_DRAG_HELPER
        DockDragRunner.shared.cancel()
        #endif
        completion = nil
        currentDoneFile = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Only the title bar moves the panel, so dragging a row always drags the app.
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishStep() }
        }
        return panel
    }

    // The frame of the System Settings window in AppKit screen coordinates.
    // The window list exposes bounds without any permission; only window titles
    // are withheld, and those are not needed.
    private func systemSettingsWindowFrame() -> NSRect? {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .map { $0.processIdentifier }
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }

        var best: CGRect?
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsValue = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue),
                  bounds.width >= 400, bounds.height >= 300 else { continue }
            if best.map({ bounds.width * bounds.height > $0.width * $0.height }) ?? true {
                best = bounds
            }
        }
        guard let bounds = best else { return nil }
        // Window-list bounds use a top-left origin on the primary display.
        return NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    // This app's main window, for steps that do not involve System Settings.
    private func appWindowFrame() -> NSRect? {
        NSApp.windows
            .filter { $0.isVisible && !$0.isSheet && !($0 is NSPanel) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?
            .frame
    }

    // Leave a small gap beside the Dock and keep the whole palette in the
    // usable screen area. The saved edge also works when the Dock is hidden.
    private func dockOrigin(for panel: NSPanel) -> NSPoint? {
        let anchor = dockAnchorOverride ?? appWindowFrame()
        let edge: String?
        #if DOCK_DRAG_HELPER
        edge = dockEdgeOverride
        #else
        edge = dockEdgeOverride ?? (CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String)
        #endif
        let screens = NSScreen.screens.sorted { first, second in
            guard let anchor else { return first == NSScreen.main && second != NSScreen.main }
            let a = first.frame.intersection(anchor)
            let b = second.frame.intersection(anchor)
            return a.width * a.height > b.width * b.height
        }
        // A visible Dock reserves space at its edge. Prefer that display when
        // it differs from the one containing the setup window.
        let screen = screens.first { screen in
            switch edge {
            case "left": return screen.visibleFrame.minX - screen.frame.minX > 8
            case "right": return screen.frame.maxX - screen.visibleFrame.maxX > 8
            default: return screen.visibleFrame.minY - screen.frame.minY > 8
            }
        } ?? screens.first
        guard let screen else { return nil }

        let area = screen.visibleFrame
        let size = panel.frame.size
        let gap: CGFloat = 16
        var origin: NSPoint
        switch edge {
        case "left":
            origin = NSPoint(x: area.minX + gap, y: area.midY - size.height / 2)
        case "right":
            origin = NSPoint(x: area.maxX - size.width - gap, y: area.midY - size.height / 2)
        default:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + gap)
        }
        origin.x = max(area.minX, min(origin.x, area.maxX - size.width))
        origin.y = max(area.minY, min(origin.y, area.maxY - size.height))
        return origin
    }

    // The spot beside the window the step goes with, top-aligned: System
    // Settings for guided settings steps, otherwise this app's window. Nil
    // while that window is not on screen yet.
    private func targetOrigin(for panel: NSPanel) -> NSPoint? {
        if currentStep == .dock { return dockOrigin(for: panel) }
        let usesSettings = currentStep?.usesSystemSettings ?? true
        guard let anchor = usesSettings ? systemSettingsWindowFrame() : appWindowFrame() else { return nil }
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? anchor
        let gap: CGFloat = 16
        var origin = NSPoint(x: anchor.maxX + gap, y: anchor.maxY - size.height)
        if origin.x + size.width > area.maxX {
            origin.x = anchor.minX - size.width - gap
        }
        if origin.x < area.minX {
            // No room on either side: overlap the window's right edge.
            origin.x = min(anchor.maxX - size.width - gap, area.maxX - size.width)
        }
        origin.y = max(area.minY, min(origin.y, area.maxY - size.height))
        return origin
    }

    private func fallbackOrigin(for panel: NSPanel) -> NSPoint {
        let size = panel.frame.size
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return .zero }
        if currentStep?.usesSystemSettings == false {
            return NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        }
        return NSPoint(x: area.maxX - size.width - 24, y: area.maxY - size.height - 24)
    }

    // Wait for the System Settings window (it is usually still opening when
    // the script sends the URL), then appear in the final spot with a short
    // fade. Never show first and jump later. A panel that is already visible
    // slides to its new spot instead.
    private func placeAndReveal(_ panel: NSPanel, token: Int, attempt: Int) {
        guard token == positioningToken else { return }

        let origin: NSPoint
        if let target = targetOrigin(for: panel) {
            origin = target
        } else if currentStep?.usesSystemSettings != false && attempt < 12 {
            // Keep looking for up to about three seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.placeAndReveal(panel, token: token, attempt: attempt + 1)
            }
            return
        } else {
            origin = fallbackOrigin(for: panel)
        }

        if panel.isVisible {
            var frame = panel.frame
            frame.origin = origin
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            // Show above System Settings without taking focus away from Terminal.
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 1
            }
        }
    }
}

private struct DragPaletteView: View {
    let step: DragPaletteStep
    let apps: [InstalledApp]
    let openSettings: () -> Void
    let done: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(step.heading, systemImage: step.symbol)
                .font(.headline)
            Text(step.instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let command = step.command {
                commandBox(command)
            } else if apps.isEmpty {
                Text(step.emptyText)
                    .font(.callout)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(apps) { app in
                            AppDragRow(app: app, step: step)
                                .frame(height: 48)
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(apps.count) * 52 + 8, 300))
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.separator, lineWidth: 1)
                }
                Text(step.tip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let title = step.openButtonTitle {
                    Button(title, action: openSettings)
                }
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .help("Continue setup")
            }
        }
        .padding(16)
        .frame(width: step.command == nil ? 340 : 400)
    }

    // The command as selectable text, with a button that copies it exactly.
    private func commandBox(_ command: String) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel("Copy the command")
        }
    }
}

// A row that acts as a Finder-style drag source for the app's file URL.
private struct AppDragRow: NSViewRepresentable {
    let app: InstalledApp
    let step: DragPaletteStep

    func makeNSView(context: Context) -> AppDragView { AppDragView(app: app, step: step) }
    func updateNSView(_ nsView: AppDragView, context: Context) {}
}

final class AppDragView: NSView, NSDraggingSource {
    private let app: InstalledApp
    private let step: DragPaletteStep
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let hintView = NSImageView()
    private var mouseDownEvent: NSEvent?

    init(app: InstalledApp, step: DragPaletteStep) {
        self.app = app
        self.step = step
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.image = app.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = app.name
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        hintView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag handle")
        hintView.contentTintColor = .tertiaryLabelColor
        hintView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(hintView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintView.leadingAnchor, constant: -8),
            hintView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hintView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Drag \(app.name) into \(step.dragDestination)"
        setAccessibilityLabel("Drag \(app.name) into \(step.dragDestination)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Start a drag on the first click even while another app is frontmost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A click on a row must begin an app drag, never move the panel.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let origin = convert(start.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - origin.x, current.y - origin.y) > 4 else { return }
        mouseDownEvent = nil

        let item = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: app.path))
        let dragSize = NSSize(width: 64, height: 64)
        item.setDraggingFrame(
            NSRect(x: current.x - dragSize.width / 2, y: current.y - dragSize.height / 2, width: dragSize.width, height: dragSize.height),
            contents: app.icon
        )
        beginDraggingSession(with: [item], event: start, source: self)
    }

    static func pasteboardItem(for path: String) -> NSPasteboardItem {
        // Publish only the app's location, not its contents. macOS still handles
        // file-access checks for this payload; a plain item does not bypass them.
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return pasteboardItem
    }

    static func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        // All app palettes use the same drag contract. Step titles and window
        // placement must not change which operations the destination can use.
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.sourceOperationMask(for: context)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
}
