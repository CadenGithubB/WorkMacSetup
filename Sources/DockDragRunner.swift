import Foundation

/// Owns the restricted Dock drag helper without giving it setup state or files.
@MainActor
final class DockDragRunner {
    static let shared = DockDragRunner()

    private var process: Process?
    private var generation = UUID()
    private var completion: ((Int32) -> Void)?

    /// Includes the brief interval between exit and delivery of its callback.
    var isRunning: Bool { process != nil }

    /// Replaces an earlier helper. Only this invocation may deliver completion.
    func start(executable: URL, arguments: [String], onFinish: @escaping (Int32) -> Void) throws {
        cancel()
        let currentGeneration = generation
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = arguments
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        helper.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self,
                      self.generation == currentGeneration,
                      self.process === finished else { return }
                self.process = nil
                let onFinish = self.completion
                self.completion = nil
                onFinish?(status)
            }
        }
        process = helper
        completion = onFinish
        do {
            try helper.run()
        } catch {
            helper.terminationHandler = nil
            process = nil
            completion = nil
            throw error
        }
    }

    /// Cancellation is not Done: never advance setup for a cancelled helper.
    func cancel() {
        generation = UUID()
        let previous = process
        process = nil
        completion = nil
        previous?.terminationHandler = nil
        if let previous, previous.isRunning {
            previous.terminate()
        }
    }
}
