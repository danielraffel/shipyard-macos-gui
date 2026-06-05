import Foundation

/// Drives whether this Mac participates in the CI pool, by loading/unloading the
/// lane's launchd runner agent and reading its live status. No GUI state here.
enum CIServingService {
    /// Resolve a lane's installed/serving status. Building/waiting activity is
    /// fetched separately (`activity(for:repos:)`) since it needs the network.
    static func status(for lane: CIServingLane) async -> CIServingStatus {
        let installed = FileManager.default.fileExists(atPath: lane.plistPath)
        guard installed else {
            return CIServingStatus(installed: false, serving: false)
        }
        let serving = await launchctlLoaded(lane.agentLabel)
        return CIServingStatus(installed: true, serving: serving)
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

    /// How many of THIS lane's runners are building (busy with a job) vs waiting
    /// (online + idle, a warm VM available for jobs / overflow). Driven by the
    /// GitHub Actions runner state — a runner is the source of truth for "a job
    /// is running" in a way a local VM count can't be (a VM can be up and idle).
    /// Matches runners whose label set is a superset of this lane's labels, so
    /// the counts are this-platform (and machine-unique where the labels are,
    /// e.g. `pulp-build-m5`). Summed across the given repos.
    static func activity(for lane: CIServingLane, repos: [String]) async -> (building: Int, waiting: Int) {
        let labels = lane.runnerLabels()
        guard !labels.isEmpty,
              let gh = ShipyardProcessEnvironment.findExecutable(named: "gh")
        else { return (0, 0) }
        var building = 0, waiting = 0
        for repo in repos {
            // `--paginate --slurp` walks every page (pools can exceed the 100/page
            // REST max) and wraps the page objects in a JSON array. parseRunnerActivity
            // handles that array, a single page object, or a bare runner array.
            let result = await run(gh, ["api", "--paginate", "--slurp",
                                        "repos/\(repo)/actions/runners?per_page=100"])
            guard result.exitCode == 0 else { continue }
            let counts = parseRunnerActivity(result.stdout, laneLabels: labels)
            building += counts.building
            waiting += counts.waiting
        }
        return (building, waiting)
    }

    /// Pure parser (testable): count online runners whose labels ⊇ `laneLabels`
    /// (this lane on this machine), split into busy (building) and idle (waiting).
    /// Case-insensitive (GitHub capitalizes default labels like `macOS`/`ARM64`).
    /// Accepts the `gh api --paginate --slurp` array of page objects, a single
    /// `{runners:[…]}` page, or a bare array of runners.
    static func parseRunnerActivity(_ json: String, laneLabels: [String]) -> (building: Int, waiting: Int) {
        let want = Set(laneLabels.map { $0.lowercased() })
        guard !want.isEmpty,
              let data = json.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data)
        else { return (0, 0) }

        var runners: [[String: Any]] = []
        if let page = top as? [String: Any] {
            runners = page["runners"] as? [[String: Any]] ?? []
        } else if let array = top as? [[String: Any]] {
            for element in array {
                if let pageRunners = element["runners"] as? [[String: Any]] {
                    runners += pageRunners                       // a page object
                } else if element["labels"] != nil || element["status"] != nil {
                    runners.append(element)                      // a bare runner
                }
            }
        }

        var building = 0, waiting = 0
        for runner in runners {
            guard (runner["status"] as? String)?.lowercased() == "online" else { continue }
            let have = Set(((runner["labels"] as? [[String: Any]]) ?? [])
                .compactMap { ($0["name"] as? String)?.lowercased() })
            guard want.isSubset(of: have) else { continue }
            if (runner["busy"] as? Bool) == true { building += 1 } else { waiting += 1 }
        }
        return (building, waiting)
    }

    private struct ProcResult { let stdout: String; let exitCode: Int32 }

    /// Minimal one-shot runner (stdout drained before wait; launchctl/gh output
    /// is small so there's no large-pipe deadlock risk). Self-contained so this
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
