import Foundation

/// Result of a one-shot `shipyard` invocation.
struct ShipyardCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 }
}

/// Thread-safe holder for the running process so a cancelled Task can tear it down.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    /// SIGTERM, then SIGKILL after a short grace, so a cancelled Task never leaves
    /// a stray `shipyard` running.
    func terminate() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Runs `binary args...` in an optional working directory and returns stdout,
/// stderr, and the exit code.
///
/// Unlike `runShipyardCapturingStdout`, this:
/// - accepts a `currentDirectoryPath` (routing commands must run in the selected
///   repo checkout), and
/// - drains stdout AND stderr concurrently before waiting (the old helper left
///   stderr unread, which can deadlock on large error output), and
/// - kills the child on timeout or Task cancellation.
enum ShipyardCommandRunner {
    static func run(
        binary: String,
        args: [String],
        currentDirectoryPath: String?,
        timeout: TimeInterval = 30
    ) async -> ShipyardCommandResult {
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ShipyardCommandResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = args
                    if let cwd = currentDirectoryPath {
                        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                    }
                    ShipyardProcessEnvironment.configure(process)
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe

                    // Drain both pipes concurrently so neither deadlocks on a full
                    // buffer while we wait.
                    var outData = Data()
                    var errData = Data()
                    let group = DispatchGroup()
                    let lock = NSLock()
                    func drain(_ handle: FileHandle, store: @escaping (Data) -> Void) {
                        group.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            let data = handle.readDataToEndOfFile()
                            lock.lock(); store(data); lock.unlock()
                            group.leave()
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        cont.resume(returning: ShipyardCommandResult(
                            stdout: "",
                            stderr: "failed to launch \(binary): \(error.localizedDescription)",
                            exitCode: -1))
                        return
                    }
                    box.set(process)
                    drain(outPipe.fileHandleForReading) { outData = $0 }
                    drain(errPipe.fileHandleForReading) { errData = $0 }

                    let watchdog = DispatchWorkItem { box.terminate() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                    process.waitUntilExit()
                    watchdog.cancel()
                    group.wait()
                    cont.resume(returning: ShipyardCommandResult(
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? "",
                        exitCode: process.terminationStatus))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}
