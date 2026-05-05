import Foundation

/// Runs any `gh <...>` invocation, returns stdout. Shared by GitHub
/// Actions polling + cancel/rerun.
func runGHCapturing(
    executable: String,
    args: [String],
    timeout: TimeInterval = 20
) async -> String {
    let box = ProcessContinuationBox()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            guard box.install(continuation: cont) else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.cancel()
            }
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                guard box.set(process: process) else { return }
                do {
                    try process.run()
                } catch {
                    box.complete("")
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                box.complete(String(data: data, encoding: .utf8) ?? "")
            }
        }
    } onCancel: {
        box.cancel()
    }
}

private final class ProcessContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var process: Process?
    private var completed = false

    func install(continuation: CheckedContinuation<String, Never>) -> Bool {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(returning: "")
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func set(process: Process) -> Bool {
        lock.lock()
        if completed {
            lock.unlock()
            process.terminate()
            return false
        }
        self.process = process
        lock.unlock()
        return true
    }

    func complete(_ output: String) {
        let cont: CheckedContinuation<String, Never>?
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        completed = true
        cont = continuation
        continuation = nil
        process = nil
        lock.unlock()
        cont?.resume(returning: output)
    }

    func cancel() {
        let cont: CheckedContinuation<String, Never>?
        let proc: Process?
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        completed = true
        cont = continuation
        proc = process
        continuation = nil
        process = nil
        lock.unlock()
        if proc?.isRunning == true {
            proc?.terminate()
        }
        cont?.resume(returning: "")
    }
}
