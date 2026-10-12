import Foundation

// Compiles with Sources/DockDragRunner.swift only. These fixtures never open
// an app, inspect user data, change permissions, or interact with the Dock.
@main
struct DockDragRunnerTests {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workmacsetup-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let exitFixture = directory.appendingPathComponent("exit.sh")
        try Data("exit \"$1\"\n".utf8).write(to: exitFixture)
        let waitFixture = directory.appendingPathComponent("wait.sh")
        try Data("exec /bin/sleep 1\n".utf8).write(to: waitFixture)
        let shell = URL(fileURLWithPath: "/bin/sh")
        let runner = DockDragRunner()
        defer { runner.cancel() }
        var results: [Int32] = []

        try runner.start(executable: shell, arguments: [exitFixture.path, "0"]) {
            require(Thread.isMainThread, "completion must run on the main thread")
            require(!runner.isRunning, "completed run must be cleared before callback")
            results.append($0)
        }
        require(runner.isRunning, "successful launch should be tracked")
        require(waitUntil { results == [0] }, "exit zero should complete once")

        try runner.start(executable: shell, arguments: [exitFixture.path, "7"]) { results.append($0) }
        require(waitUntil { results == [0, 7] }, "nonzero exit should be delivered")

        try runner.start(executable: shell, arguments: [waitFixture.path]) { _ in
            fatalError("cancelled helper must not complete")
        }
        runner.cancel()
        runner.cancel()
        require(!runner.isRunning, "cancel must immediately clear tracked run")
        pump(for: 0.15)
        require(results == [0, 7], "cancel must not add a result")

        try runner.start(executable: shell, arguments: [waitFixture.path]) { _ in
            fatalError("replaced helper must not complete")
        }
        try runner.start(executable: shell, arguments: [exitFixture.path, "0"]) { results.append($0) }
        require(waitUntil { results == [0, 7, 0] }, "replacement must finish normally")
        pump(for: 0.15)
        require(results == [0, 7, 0], "late termination must not complete a second time")

        // A process may exit while its main-queue callback is still pending.
        // Cancel before servicing the run loop; even that callback must be stale.
        try runner.start(executable: shell, arguments: [exitFixture.path, "0"]) { _ in
            fatalError("cancelled pending callback must not complete")
        }
        Thread.sleep(forTimeInterval: 0.15)
        runner.cancel()
        pump(for: 0.15)

        do {
            try runner.start(executable: directory.appendingPathComponent("missing-helper"), arguments: []) { _ in
                fatalError("failed launch must not complete")
            }
            fatalError("missing executable must throw")
        } catch {
            require(!runner.isRunning, "failed launch must leave no active run")
        }
        try runner.start(executable: shell, arguments: [exitFixture.path, "7"]) { results.append($0) }
        require(waitUntil { results == [0, 7, 0, 7] }, "runner must recover after failed launch")
        print("DockDragRunnerTests passed")
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        return condition()
    }

    @MainActor
    private static func pump(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
}
