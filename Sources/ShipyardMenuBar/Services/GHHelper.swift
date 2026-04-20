import Foundation

/// Runs any `gh <...>` invocation, returns stdout. Shared by GitHub
/// Actions polling + cancel/rerun.
func runGHCapturing(executable: String, args: [String]) async -> String {
    await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                cont.resume(returning: "")
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
