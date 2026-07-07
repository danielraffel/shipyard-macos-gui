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

    /// Parse a tartci lease/status JSON body. Tolerant by design, it accepts the
    /// three shapes the toolkit has actually emitted:
    ///
    /// 1. The **live governor** (`tartci leases --json`): a top-level `capacity`
    ///    object carrying `used_cores`/`total_cores`/`used_mem_mb`/`total_mem_mb`
    ///    (note the `_mem_mb` spelling), plus a top-level `leases[]` array.
    /// 2. **`tartci status --json`**: the same block folded one level down under a
    ///    `leases` object (`leases.capacity`, `leases.leases[]`), so we descend
    ///    into it before reading.
    /// 3. **Assumed/legacy** shapes: a nested `{cores:{used,total}}` /
    ///    `{memory_mb:{used,total}}` object, or flat aliases, or a `held_leases`
    ///    int — kept so an older or differently-shaped governor still reads.
    ///
    /// Reads what it can and ignores the rest; picks up `tier` when present.
    /// Returns nil for empty/invalid JSON or a body with no lease fields at all
    /// (so `read` can fall through to the next probe). Internal for tests.
    static func parse(_ json: String) -> TartciLeaseSnapshot? {
        guard let data = json.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `tartci status --json` nests the whole lease report under a `leases`
        // OBJECT; `tartci leases --json` puts it at the top level (there `leases`
        // is instead an ARRAY). Descend into the object form so both shapes read
        // the same below.
        let block: [String: Any] = (top["leases"] as? [String: Any]) ?? top
        // Live governor budgets live inside a `capacity` object.
        let capacity = block["capacity"] as? [String: Any]

        let (usedCores, totalCores) = usedTotal(
            capacity: capacity, container: block, nestedKey: "cores",
            usedAliases: ["used_cores", "cores_used"],
            totalAliases: ["total_cores", "cores_total", "core_count"])
        let (usedMem, totalMem) = usedTotal(
            capacity: capacity, container: block, nestedKey: "memory_mb",
            usedAliases: ["used_mem_mb", "used_memory_mb", "memory_used_mb"],
            totalAliases: ["total_mem_mb", "total_memory_mb", "memory_total_mb"])

        let held: Int = {
            // Prefer a leases array wherever it lives (top-level for `leases
            // --json`, or under the nested block for `status --json`).
            if let leases = block["leases"] as? [Any] { return leases.count }
            if let leases = top["leases"] as? [Any] { return leases.count }
            return intValue(block["held_leases"]) ?? intValue(block["held"]) ?? 0
        }()

        let tier = (block["tier"] as? String ?? top["tier"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        // A body that carried none of the governor's fields isn't a lease report
        // (e.g. `tartci status --json` on a build without the governor).
        guard totalCores > 0 || totalMem > 0 || held > 0 || tier != nil else { return nil }

        return TartciLeaseSnapshot(
            tier: tier,
            usedCores: usedCores, totalCores: totalCores,
            usedMemoryMB: usedMem, totalMemoryMB: totalMem,
            heldLeases: held)
    }

    /// Pull a used/total pair, trying (in order): the live governor's `capacity`
    /// object (aliased keys like `used_cores`/`used_mem_mb`), a nested
    /// `{used,total}` object under `nestedKey`, then flat aliased keys on the
    /// container.
    private static func usedTotal(
        capacity: [String: Any]?, container: [String: Any], nestedKey: String,
        usedAliases: [String], totalAliases: [String]
    ) -> (used: Int, total: Int) {
        // 1) Live governor: {capacity: {used_cores, total_cores, used_mem_mb, …}}.
        if let cap = capacity {
            let used = usedAliases.lazy.compactMap { intValue(cap[$0]) }.first
            let total = totalAliases.lazy.compactMap { intValue(cap[$0]) }.first
            if used != nil || total != nil { return (used ?? 0, total ?? 0) }
        }
        // 2) Nested {used, total} object under `nestedKey`.
        if let nested = container[nestedKey] as? [String: Any] {
            return (intValue(nested["used"]) ?? 0, intValue(nested["total"]) ?? 0)
        }
        // 3) Flat aliased keys on the container.
        let used = usedAliases.lazy.compactMap { intValue(container[$0]) }.first ?? 0
        let total = totalAliases.lazy.compactMap { intValue(container[$0]) }.first ?? 0
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
