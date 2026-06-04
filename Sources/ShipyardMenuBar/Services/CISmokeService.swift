import Foundation

/// Runs a local emulated-x86_64 smoke check by shelling out to the `tartci`
/// cross lane. No GUI state here — the AppStore owns published status.
///
/// Unlike CIServingService (which `launchctl load/unload`s a pool runner), this
/// runs ONE `tartci up <os> --target-arch x86_64` to completion: tartci clones a
/// throwaway VM, cross-builds, runs the emulated test subset, and discards the
/// clone. A smoke signal, not a gate.
enum CISmokeService {
    /// Resolve the `tartci` dispatcher. It is usually not on the login PATH, so
    /// also probe common checkout / install locations.
    static func resolveTartci(fileManager: FileManager = .default) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            ProcessInfo.processInfo.environment["TARTCI_BIN"],
            home + "/.local/bin/tartci",
            "/opt/homebrew/bin/tartci",
            "/usr/local/bin/tartci",
        ].compactMap { $0 }
        return ShipyardProcessEnvironment.findExecutable(
            named: "tartci", candidates: candidates, fileManager: fileManager)
    }

    static func isAvailable() -> Bool { resolveTartci() != nil }

    /// Run a lane to completion and return its terminal status. `selfTest` runs
    /// the lightweight, golden-agnostic toolchain+emulator proof.
    static func run(_ lane: CISmokeLane, selfTest: Bool = false) async -> CISmokeStatus {
        guard let tartci = resolveTartci() else { return .unavailable }
        let args = selfTest ? lane.selfTestArgs : lane.commandArgs
        let result = await runProcess(tartci, args)
        return CISmokeStatus.terminal(exitCode: result.exitCode, outputTail: result.tail)
    }

    private struct ProcResult { let tail: String; let exitCode: Int32 }

    /// Spawn `binary args…`, stream-drain stdout+stderr, keep only the tail (the
    /// run is long and chatty; we surface a one-line result, not the whole log).
    private static func runProcess(_ binary: String, _ args: [String]) async -> ProcResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = args
                ShipyardProcessEnvironment.configure(process)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: ProcResult(
                        tail: "could not launch tartci: \(error.localizedDescription)",
                        exitCode: -1))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                // Keep the last ~16 lines so a failure's cause is visible.
                let tail = text.split(separator: "\n").suffix(16).joined(separator: "\n")
                cont.resume(returning: ProcResult(tail: tail, exitCode: process.terminationStatus))
            }
        }
    }
}
