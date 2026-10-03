import AppKit
import SwiftUI

// Handles workmacsetup://drag-palette URLs sent by post-enrollment.sh when it
// reaches a guided System Settings step. The URL only names the step and the
// installed apps to show in a floating drag palette; nothing is launched and
// no setting is changed by the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DragPaletteController.shared.handle(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SetupRun.current?.stopForQuit()
    }
}

// The guided steps that use the drag palette. Raw values match the script.
enum DragPaletteStep: String {
    case loginItems = "login-items"
    case screenRecording = "screen-recording"

    var windowTitle: String {
        switch self {
        case .loginItems: return "Drag into Open at Login"
        case .screenRecording: return "Allow Screen Recording"
        }
    }

    var heading: String {
        switch self {
        case .loginItems: return "Add these apps to Open at Login"
        case .screenRecording: return "Allow these apps to record the screen"
        }
    }

    var instructions: String {
        switch self {
        case .loginItems:
            return "In System Settings > General > Login Items, drag each app below into the Open at Login list. When they all appear there, click Done to continue setup."
        case .screenRecording:
            return "In System Settings > Privacy & Security > Screen & System Audio Recording, drag each app below into the list and turn on its switch. Then click Done to continue setup."
        }
    }

    var emptyText: String {
        switch self {
        case .loginItems:
            return "No apps were selected. Use the + button under Open at Login to add any you need, then click Done."
        case .screenRecording:
            return "No apps were selected. Use the + button in Screen & System Audio Recording to add any you need, turn on their switches, then click Done."
        }
    }

    var tip: String {
        switch self {
        case .loginItems:
            return "Tip: if dragging does not work, click + in System Settings and choose the app."
        case .screenRecording:
            return "Tip: if dragging does not work, click + and choose the app. macOS may ask you to quit and reopen the app."
        }
    }

    var openButtonTitle: String {
        switch self {
        case .loginItems: return "Open Login Items"
        case .screenRecording: return "Open Screen Recording"
        }
    }

    var settingsURL: URL {
        switch self {
        case .loginItems:
            return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
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
        show(step: step, apps: apps.filter { seen.insert($0.path).inserted }, doneFile: doneFile, quitsSettings: isLastStep)
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

    func show(step: DragPaletteStep, apps: [InstalledApp], doneFile: URL? = nil, quitsSettings: Bool = false) {
        currentDoneFile = doneFile
        quitsSettingsOnFinish = quitsSettings
        let content = DragPaletteView(
            step: step,
            apps: apps,
            openSettings: { NSWorkspace.shared.open(step.settingsURL) },
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
            self?.finishStep()
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

    // The spot beside the System Settings window, top-aligned, or nil when
    // that window is not on screen yet.
    private func targetOrigin(for panel: NSPanel) -> NSPoint? {
        guard let settings = systemSettingsWindowFrame() else { return nil }
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? settings
        let gap: CGFloat = 16
        var origin = NSPoint(x: settings.maxX + gap, y: settings.maxY - size.height)
        if origin.x + size.width > area.maxX {
            origin.x = settings.minX - size.width - gap
        }
        if origin.x < area.minX {
            // No room on either side: overlap the settings window's right edge.
            origin.x = min(settings.maxX - size.width - gap, area.maxX - size.width)
        }
        origin.y = max(area.minY, min(origin.y, area.maxY - size.height))
        return origin
    }

    private func fallbackOrigin(for panel: NSPanel) -> NSPoint {
        let size = panel.frame.size
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return .zero }
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
        } else if attempt < 12 {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(step.heading, systemImage: "hand.draw")
                .font(.headline)
            Text(step.instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if apps.isEmpty {
                Text(step.emptyText)
                    .font(.callout)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(apps) { app in
                        AppDragRow(app: app, step: step)
                            .frame(height: 48)
                    }
                }
                .padding(6)
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
                Button(step.openButtonTitle, action: openSettings)
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .help("Continue setup")
            }
        }
        .padding(16)
        .frame(width: 340)
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
        toolTip = "Drag \(app.name) into the \(step.windowTitle) list"
        setAccessibilityLabel("Drag \(app.name) into \(step.windowTitle)")
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

        // Offer the app as a public.file-url pasteboard item, as a Finder drag
        // does. Writing an NSURL instead makes AppKit try to issue a sandbox
        // extension for the app bundle, which macOS reports as an attempt to
        // modify another app and blocks under App Management. A plain
        // pasteboard item carries the same file URL without that.
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(URL(fileURLWithPath: app.path).absoluteString, forType: .fileURL)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let dragSize = NSSize(width: 64, height: 64)
        item.setDraggingFrame(
            NSRect(x: current.x - dragSize.width / 2, y: current.y - dragSize.height / 2, width: dragSize.width, height: dragSize.height),
            contents: app.icon
        )
        beginDraggingSession(with: [item], event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
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
