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

    /// How many trailing lines of output we keep for the row's result detail.
    private static let tailLineCap = 16

    /// Spawn `binary args…` and stream-drain combined stdout/stderr into a
    /// BOUNDED tail buffer — a cross-build can emit megabytes of compiler/test
    /// output, and the menu-bar app only needs the last few lines, so we never
    /// hold the whole log in memory (and draining as we go avoids the classic
    /// full-pipe deadlock).
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
                let handle = pipe.fileHandleForReading
                var tailLines: [String] = []        // bounded ring: last `tailLineCap` lines
                var pending = ""                     // current partial line
                func absorbLine(_ line: String) {
                    tailLines.append(line)
                    if tailLines.count > tailLineCap {
                        tailLines.removeFirst(tailLines.count - tailLineCap)
                    }
                }
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    pending += String(decoding: chunk, as: UTF8.self)
                    while let nl = pending.firstIndex(of: "\n") {
                        absorbLine(String(pending[..<nl]))
                        pending = String(pending[pending.index(after: nl)...])
                    }
                    // Guard against a pathological newline-less stream: keep only
                    // the trailing 8 KB of an unterminated line.
                    if pending.utf8.count > 8192 {
                        pending = String(pending.suffix(4096))
                    }
                }
                if !pending.isEmpty { absorbLine(pending) }
                process.waitUntilExit()
                cont.resume(returning: ProcResult(
                    tail: tailLines.joined(separator: "\n"),
                    exitCode: process.terminationStatus))
            }
        }
    }
}
