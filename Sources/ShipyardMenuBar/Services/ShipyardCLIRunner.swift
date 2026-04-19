import Foundation

/// Long-lived subprocess wrapper around `shipyard watch --json --follow`.
/// Emits one line per NDJSON event. Caller decides how to decode and apply.
///
/// Runs off the main actor; callers should hop back to `@MainActor` before
/// mutating UI state. Survives transient EOF by respawning on a backoff.
actor ShipyardCLIRunner {
    private let executable: String
    private let args: [String]
    private var process: Process?
    private var task: Task<Void, Never>?

    init(executable: String, args: [String] = ["--json", "watch", "--follow"]) {
        self.executable = executable
        self.args = args
    }

    func start(onLine: @Sendable @escaping (String) -> Void) {
        stop()
        task = Task.detached { [executable, args] in
            while !Task.isCancelled {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle(forWritingAtPath: "/dev/null")
                do {
                    try process.run()
                } catch {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                let handle = pipe.fileHandleForReading
                var buffer = Data()
                while !Task.isCancelled, process.isRunning {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<newline)
                        buffer.removeSubrange(0...newline)
                        if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                            onLine(line)
                        }
                    }
                }
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        process?.terminate()
        process = nil
    }

    deinit {
        task?.cancel()
        process?.terminate()
    }
}
