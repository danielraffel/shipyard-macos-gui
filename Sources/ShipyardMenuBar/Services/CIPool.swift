import Foundation

/// Host-level CI-pool participation via the single `tartci pool` implementation.
///
/// `tartci pool off` writes `~/.config/tartci/native-build-participation=0` AND
/// `launchctl unload`s every CI runner agent this host owns
/// (`com.danielraffel.pulp.tart-runner`, `tart-runner-*`, `qemu-runner`,
/// `qemu-runner-*`, `actions.runner.*`); `pool on` reverses both. Because the
/// CLI owns the full runner-agent set — including the `actions.runner.*`
/// GitHub-native runners the GUI's per-lane discovery does NOT cover — the GUI
/// delegates its "all lanes on/off" master switch here instead of duplicating
/// the launchctl + participation-file logic.
///
/// Per-lane toggles keep doing pure `launchctl load/unload` (see
/// `CIServingService.setServing`) for granular control; only the host-wide
/// opt-in/out routes through this service.
enum CIPool {
    /// Resolve the `tartci` dispatcher, reusing the same probe locations as the
    /// rest of the GUI (`TartciLeases.resolveTartci`). nil ⇒ tartci not on this
    /// host, so callers fall back to the per-lane `launchctl` fan-out.
    static func resolveTartci(fileManager: FileManager = .default) -> String? {
        TartciLeases.resolveTartci(fileManager: fileManager)
    }

    /// Turn host-wide pool participation on (`tartci pool on`) or off
    /// (`tartci pool off`). Returns `true` when the CLI ran and exited cleanly
    /// (the GUI treats that as "delegated"); `false` when tartci is absent or the
    /// command failed, so the caller can fall back to per-lane control.
    static func setParticipating(_ on: Bool) async -> Bool {
        guard let tartci = resolveTartci() else { return false }
        let result = await run(tartci, ["pool", on ? "on" : "off"])
        return result.exitCode == 0
    }

    /// Read host-wide participation from `tartci pool status --json`. Returns the
    /// parsed `participating` bool, or nil when tartci is absent / the output is
    /// unparseable (so the caller can fall back to reading the participation file
    /// directly via `LeaseParticipation.read`).
    static func readParticipating() async -> Bool? {
        guard let tartci = resolveTartci() else { return nil }
        let result = await run(tartci, ["pool", "status", "--json"])
        guard result.exitCode == 0 else { return nil }
        return parseParticipating(result.stdout)
    }

    /// Parse the `participating` bool out of a `tartci pool status --json` body:
    /// `{"host":.., "participating":bool, "runners":[{"label":.., "loaded":bool}]}`.
    /// Tolerant of a stringified/int bool ("0"/"1", 0/1). Returns nil when the
    /// field is absent or the body isn't a JSON object. Internal for tests.
    static func parseParticipating(_ json: String) -> Bool? {
        guard let data = json.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return boolValue(top["participating"])
    }

    /// Coerce a JSON bool / number / string into a Bool (CLIs sometimes emit
    /// `1`/`0` or `"true"`/`"false"` instead of a native bool).
    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let i = any as? Int { return i != 0 }
        if let d = any as? Double { return d != 0 }
        if let s = any as? String {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private struct ProcResult { let stdout: String; let exitCode: Int32 }

    /// Bounded one-shot runner (stdout drained before wait; `tartci pool` output
    /// is small). Self-contained so this feature doesn't couple to other
    /// services' private runners, matching `TartciLeases`/`CIServingService`.
    private static func run(_ binary: String, _ args: [String]) async -> ProcResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = args
                ShipyardProcessEnvironment.configure(process)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: ProcResult(stdout: "", exitCode: -1))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: ProcResult(
                    stdout: String(data: data, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus))
            }
        }
    }
}
