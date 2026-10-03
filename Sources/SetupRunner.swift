import AppKit
import SwiftUI

// Setup runs inside the app. The script's output is captured for the result
// window's Details section, and each step reports its state through a small
// status file, so the window can show exactly which step failed. Nothing the
// script does needs an administrator password.

struct SetupOutcome: Equatable {
    enum Kind: Equatable { case success, failure, stopped }
    let kind: Kind
    let exitCode: Int32
}

// One selected action, in the order the script runs it.
struct SetupStep: Identifiable, Equatable {
    enum State: Equatable { case pending, running, done, warning, failed, notRun }
    /// Matches the step name the script records.
    let id: String
    let title: String
    var state: State = .pending
    var message = ""
}

final class SetupRun: ObservableObject, Identifiable {
    /// The run in progress, so quitting the app can stop it.
    static weak var current: SetupRun?

    let id = UUID()

    @Published private(set) var steps: [SetupStep]
    @Published private(set) var output = ""
    @Published private(set) var outcome: SetupOutcome?
    @Published private(set) var isStopping = false

    private let workDirectory: URL
    private let statusFile: URL
    private var process: Process?
    private var buffer = Data()

    var isRunning: Bool { outcome == nil }
    var failedSteps: [SetupStep] { steps.filter { $0.state == .failed } }

    init(steps: [SetupStep], workDirectory: URL, statusFile: URL) {
        self.steps = steps
        self.workDirectory = workDirectory
        self.statusFile = statusFile
    }

    /// The latest output line without its timestamp, shown while running.
    var statusLine: String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines.last else { return "Starting…" }
        if let stamp = line.range(of: #"^\[[0-9: -]+\]\s*"#, options: .regularExpression) {
            line.removeSubrange(stamp)
        }
        return line
    }

    func start(script: URL, config: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--config", config.path]
        // No terminal input: guided steps wait for Done in their floating window.
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.append(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            // Give the pipe a moment to deliver the final lines.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.finish(status: status)
            }
        }
        try process.run()
        self.process = process
        SetupRun.current = self
    }

    /// Ends the run early. The script exits after the command it is running,
    /// so a Chrome profile change already in progress is allowed to finish.
    func stop() {
        guard let process, process.isRunning else { return }
        isStopping = true
        process.terminate()
    }

    /// Called when the app quits during a run.
    func stopForQuit() {
        if let process, process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func append(_ data: Data) {
        buffer.append(data)
        output = String(decoding: buffer, as: UTF8.self)
        refreshSteps()
    }

    // The script appends "step<TAB>state<TAB>message" lines as it goes.
    private func refreshSteps() {
        guard let text = try? String(contentsOf: statusFile, encoding: .utf8) else { return }
        var updated = steps
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let index = updated.firstIndex(where: { $0.id == fields[0] }) else { continue }
            let message = fields.count > 2 ? fields[2] : ""
            switch fields[1] {
            case "running":
                updated[index].state = .running
            case "done":
                updated[index].state = .done
                updated[index].message = ""
            case "warning":
                updated[index].state = .warning
                updated[index].message = message
            case "failed":
                updated[index].state = .failed
                updated[index].message = message
            default:
                break
            }
        }
        if updated != steps { steps = updated }
    }

    private func finish(status: Int32) {
        guard outcome == nil else { return }
        process = nil
        if SetupRun.current === self { SetupRun.current = nil }
        refreshSteps()
        try? FileManager.default.removeItem(at: workDirectory)

        var finalSteps = steps
        for index in finalSteps.indices {
            switch finalSteps[index].state {
            case .pending:
                finalSteps[index].state = .notRun
            case .running:
                finalSteps[index].state = isStopping ? .notRun : .failed
                finalSteps[index].message = isStopping ? "Stopped before it finished." : "Did not finish."
            default:
                break
            }
        }
        steps = finalSteps

        let kind: SetupOutcome.Kind
        if isStopping {
            kind = .stopped
        } else if status != 0 || !failedSteps.isEmpty {
            kind = .failure
        } else {
            kind = .success
        }
        outcome = SetupOutcome(kind: kind, exitCode: status)
        NSApp?.activate(ignoringOtherApps: true)
    }
}

// macOS only toggles a DisclosureGroup from its chevron; make the title
// text toggle it too so the whole label is an easy click target.
struct DisclosureLabel: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            Text(title)
                .font(.callout)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Collapses the section" : "Expands the section")
    }
}

// Progress while setup runs, then a quiet result card. Details shows the full
// output of the run.
struct SetupRunSheet: View {
    @ObservedObject var run: SetupRun
    let stop: () -> Void
    let dismiss: () -> Void
    @State private var showingDetails: Bool

    init(run: SetupRun, stop: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.run = run
        self.stop = stop
        self.dismiss = dismiss
        // A failure is marked on its step; Details opens on its own only when
        // setup failed outside any step.
        _showingDetails = State(initialValue: Self.failedOutsideSteps(run))
    }

    private static func failedOutsideSteps(_ run: SetupRun) -> Bool {
        run.outcome?.kind == .failure && run.failedSteps.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            if !run.steps.isEmpty {
                stepList
            }
            details
            footer
        }
        .padding(28)
        .frame(width: 500)
        .onChange(of: run.outcome) { _ in
            if Self.failedOutsideSteps(run) {
                showingDetails = true
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let outcome = run.outcome {
            Image(systemName: symbol(for: outcome.kind))
                .font(.system(size: 54))
                .foregroundStyle(tint(for: outcome.kind))
                .padding(.top, 6)
            Text(title(for: outcome.kind))
                .font(.title2.bold())
            Text(message(for: outcome.kind))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(height: 54)
                .padding(.top, 6)
            Text(run.isStopping ? "Stopping…" : "Running setup…")
                .font(.title2.bold())
            Text(run.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(run.steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    stepIcon(step.state)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.callout)
                        if !step.message.isEmpty {
                            Text(step.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(statusText(step.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $showingDetails) {
            VStack(alignment: .trailing, spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(run.output.isEmpty ? "No output yet." : run.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear
                                .frame(height: 1)
                                .id("end")
                        }
                        .padding(8)
                    }
                    .frame(height: 220)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: run.output) { _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.output, forType: .string)
                }
                .controlSize(.small)
                .disabled(run.output.isEmpty)
            }
            .padding(.top, 6)
        } label: {
            DisclosureLabel(title: "Details", isExpanded: $showingDetails)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        if run.isRunning {
            Button("Stop", action: stop)
                .disabled(run.isStopping)
        } else {
            Button("Done", action: dismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: SetupStep.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.orange)
        case .notRun:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(_ state: SetupStep.State) -> String {
        switch state {
        case .pending: return "Waiting"
        case .running: return "Running"
        case .done: return "Done"
        case .warning: return "Done with a warning"
        case .failed: return "Failed"
        case .notRun: return "Not run"
        }
    }

    private func symbol(for kind: SetupOutcome.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        }
    }

    private func tint(for kind: SetupOutcome.Kind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return .orange
        case .stopped: return .secondary
        }
    }

    private func title(for kind: SetupOutcome.Kind) -> String {
        switch kind {
        case .success: return "Setup completed"
        case .failure: return "Setup finished with errors"
        case .stopped: return "Setup stopped"
        }
    }

    private func message(for kind: SetupOutcome.Kind) -> String {
        switch kind {
        case .success:
            if run.steps.contains(where: { $0.state == .warning }) {
                return "Everything you selected has run. Review the warning below."
            }
            return "Everything you selected has run."
        case .failure:
            let failed = run.failedSteps
            if failed.count == 1 {
                return "\(failed[0].title) did not complete. Fix it, then run only that action again."
            }
            if failed.count > 1 {
                return "\(failed.count) steps did not complete. Fix them, then run only those actions again."
            }
            return "Setup stopped with an error before it finished. Details shows why."
        case .stopped:
            return "Setup was stopped before it finished. Steps that already ran are left as they are."
        }
    }
}
