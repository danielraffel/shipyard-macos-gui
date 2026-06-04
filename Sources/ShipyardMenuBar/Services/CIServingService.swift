import Foundation

/// Drives whether this Mac participates in the CI pool, by loading/unloading the
/// lane's launchd runner agent and reading its live status. No GUI state here.
enum CIServingService {
    /// Resolve a lane's current status (installed / serving / busy).
    static func status(for lane: CIServingLane) async -> CIServingStatus {
        let installed = FileManager.default.fileExists(atPath: lane.plistPath)
        guard installed else {
            return CIServingStatus(installed: false, serving: false, busyVMs: 0)
        }
        let serving = await launchctlLoaded(lane.agentLabel)
        let busy = serving ? await runningVMCount() : 0
        return CIServingStatus(installed: true, serving: serving, busyVMs: busy)
    }

    /// Turn pool participation on (load) or off (unload) for a lane.
    /// Returns true on success.
    static func setServing(_ on: Bool, lane: CIServingLane) async -> Bool {
        // `load`/`unload` match how tools/ci/setup-ci-host.sh manages the agent.
        let result = await run("/bin/launchctl", [on ? "load" : "unload", lane.plistPath])
        return result.exitCode == 0
    }

    private static func launchctlLoaded(_ label: String) async -> Bool {
        // `launchctl list <label>` exits 0 when the agent is loaded.
        await run("/bin/launchctl", ["list", label]).exitCode == 0
    }

    private static func runningVMCount() async -> Int {
        guard let tart = ShipyardProcessEnvironment.findExecutable(named: "tart") else { return 0 }
        let result = await run(
            tart, ["list", "--format", "json"], extraEnv: ["TART_HOME": tartHome()])
        return parseRunningVMCount(result.stdout)
    }

    /// Where this Mac keeps its Tart VMs. Honor an explicit `TART_HOME` (a host
    /// like the Mac Studio keeps VMs on an external volume, e.g.
    /// `/Volumes/Workshop/VMs`, NOT `~/VMs`); fall back to `~/VMs` (the default
    /// most hosts use). Counting the wrong directory was why the VM count could
    /// read 0 on a Studio that actually had VMs running.
    static func tartHome() -> String {
        if let env = ProcessInfo.processInfo.environment["TART_HOME"], !env.isEmpty {
            return env
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("VMs")
    }

    /// Pure parser (testable): count VMs reported running by `tart list --format json`.
    /// Tart has used both `"Running": true` and `"State": "running"` across versions.
    static func parseRunningVMCount(_ json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return 0 }
        return array.filter { vm in
            if let running = vm["Running"] as? Bool, running { return true }
            if let state = vm["State"] as? String, state.lowercased() == "running" { return true }
            return false
        }.count
    }

    private struct ProcResult { let stdout: String; let exitCode: Int32 }

    /// Minimal one-shot runner (stdout drained before wait; launchctl/tart output
    /// is tiny so there's no large-pipe deadlock risk). Self-contained so this
    /// feature doesn't depend on other in-flight branches.
    private static func run(
        _ binary: String, _ args: [String], extraEnv: [String: String] = [:]
    ) async -> ProcResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = args
                ShipyardProcessEnvironment.configure(process, extra: extraEnv)
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
