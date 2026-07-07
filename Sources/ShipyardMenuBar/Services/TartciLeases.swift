import Foundation

/// A parsed snapshot of the tartci lease governor's current usage on THIS Mac —
/// how many cores / MB of RAM are leased out vs. the host budget, how many
/// leases are held, and which tier the host is in. This is the read side of the
/// host-resource governor: the panel that shows whether the governor would grant
/// another native-build lease right now.
struct TartciLeaseSnapshot: Equatable {
    /// Governor tier for this host (e.g. "native-build"). nil when not reported.
    var tier: String?
    var usedCores: Int
    var totalCores: Int
    var usedMemoryMB: Int
    var totalMemoryMB: Int
    /// Number of leases currently held on this host.
    var heldLeases: Int

    /// Compact one-liner for the section, e.g. "8/12 cores · 16384/32768 MB".
    /// Omits a dimension the governor didn't report (total 0) so we never show
    /// a misleading "0/0".
    var summary: String {
        var parts: [String] = []
        if totalCores > 0 { parts.append("\(usedCores)/\(totalCores) cores") }
        if totalMemoryMB > 0 { parts.append("\(usedMemoryMB)/\(totalMemoryMB) MB") }
        if parts.isEmpty { parts.append("\(heldLeases) lease\(heldLeases == 1 ? "" : "s") held") }
        return parts.joined(separator: " · ")
    }

    /// Core-utilization fraction (0...1) for a small meter. 0 when total unknown.
    var coreFraction: Double {
        totalCores == 0 ? 0 : min(1, Double(usedCores) / Double(totalCores))
    }
}

/// Reads the tartci lease governor's live usage by shelling out locally, and
/// handles a host where the governor isn't installed. No GUI state here — the
/// AppStore owns the published value.
///
/// Runs `tartci leases --json` (falling back to `tartci status --json`) via a
/// bounded one-shot process, then parses tolerantly: the governor's JSON shape
/// may vary, so `parse` reads what it can and ignores the rest.
enum TartciLeases {
    /// Terminal state for the panel.
    enum State: Equatable {
        case notInstalled                 // tartci binary absent → "governor not installed"
        case unavailable(String)          // tartci present but leases/status unreadable
        case available(TartciLeaseSnapshot)

        var snapshot: TartciLeaseSnapshot? {
            if case .available(let s) = self { return s }
            return nil
        }
    }

    /// Resolve the `tartci` dispatcher. Usually off the login PATH, so probe the
    /// common checkout / install locations too (mirrors CISmokeService).
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

    /// Read the governor's current lease usage. `notInstalled` when tartci isn't
    /// present; `unavailable` when it is but neither subcommand returns parseable
    /// JSON (older tartci without the governor, or a transient error).
    static func read() async -> State {
        guard let tartci = resolveTartci() else { return .notInstalled }
        // Prefer the dedicated `leases` subcommand; fall back to `status` which
        // some builds fold the lease block into. Either way we only trust JSON we
        // can parse — a nonzero exit or unparseable body drops to the next probe.
        for args in [["leases", "--json"], ["status", "--json"]] {
            let result = await run(tartci, args)
            if result.exitCode == 0, let snapshot = parse(result.stdout) {
                return .available(snapshot)
            }
        }
        return .unavailable("governor not reporting leases")
    }

    /// Parse a tartci lease/status JSON body. Tolerant by design: reads nested
    /// `{cores:{used,total}}` / `{memory_mb:{used,total}}` blocks and a few common
    /// flat aliases, counts `leases[]` (or a `held_leases` int), and picks up
    /// `tier`. Returns nil for empty/invalid JSON or a body with no lease fields
    /// at all (so `read` can fall through to the next probe). Internal for tests.
    static func parse(_ json: String) -> TartciLeaseSnapshot? {
        guard let data = json.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let (usedCores, totalCores) = usedTotal(
            in: top, nestedKey: "cores",
            usedAliases: ["used_cores", "cores_used"],
            totalAliases: ["total_cores", "cores_total", "core_count"])
        let (usedMem, totalMem) = usedTotal(
            in: top, nestedKey: "memory_mb",
            usedAliases: ["used_memory_mb", "memory_used_mb"],
            totalAliases: ["total_memory_mb", "memory_total_mb"])

        let held: Int = {
            if let leases = top["leases"] as? [Any] { return leases.count }
            return intValue(top["held_leases"]) ?? intValue(top["held"]) ?? 0
        }()

        let tier = (top["tier"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // A body that carried none of the governor's fields isn't a lease report
        // (e.g. `tartci status --json` on a build without the governor).
        guard totalCores > 0 || totalMem > 0 || held > 0 || tier != nil else { return nil }

        return TartciLeaseSnapshot(
            tier: tier,
            usedCores: usedCores, totalCores: totalCores,
            usedMemoryMB: usedMem, totalMemoryMB: totalMem,
            heldLeases: held)
    }

    /// Pull a used/total pair from either a nested `{used,total}` object under
    /// `nestedKey` or flat aliased keys at the top level.
    private static func usedTotal(
        in top: [String: Any], nestedKey: String,
        usedAliases: [String], totalAliases: [String]
    ) -> (used: Int, total: Int) {
        if let nested = top[nestedKey] as? [String: Any] {
            return (intValue(nested["used"]) ?? 0, intValue(nested["total"]) ?? 0)
        }
        let used = usedAliases.lazy.compactMap { intValue(top[$0]) }.first ?? 0
        let total = totalAliases.lazy.compactMap { intValue(top[$0]) }.first ?? 0
        return (used, total)
    }

    /// Coerce a JSON number/string into an Int (governors sometimes stringify).
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private struct ProcResult { let stdout: String; let exitCode: Int32 }

    /// Bounded one-shot runner (stdout drained before wait; `tartci … --json`
    /// output is small). Self-contained so the feature doesn't couple to other
    /// services' private runners.
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
