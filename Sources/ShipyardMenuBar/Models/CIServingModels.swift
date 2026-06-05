import Foundation

/// A CI "lane" this Mac can serve — i.e. a self-hosted runner for one platform,
/// backed by a launchd agent that picks up jobs and runs each in a throwaway VM.
///
/// Each lane is a self-hosted runner LaunchAgent for one platform; toggling the
/// row `launchctl load/unload`s that agent, so the switch is universal across
/// platforms with no UI redesign. A lane only appears once its agent plist is
/// installed (by pulp's `tools/ci/setup-ci-host.sh` for macOS, or the
/// `tart-runner-linux` / `qemu-runner-windows` supervisors for the VM lanes);
/// an un-installed lane renders as "Not set up on this Mac".
struct CIServingLane: Identifiable, Equatable {
    let id: String           // stable key, e.g. "macos"
    let platform: String     // display name, e.g. "macOS"
    let agentLabel: String   // launchd label
    let plistPath: String    // ~/Library/LaunchAgents/<label>.plist

    private static func agentPlist(_ label: String) -> String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The GitHub Actions runner labels this lane registers with on THIS machine,
    /// read from the installed agent plist's `--labels` argument (e.g.
    /// `self-hosted,macos,arm64,pulp-build,pulp-build-m5`). We use these to find
    /// *this lane's* runners in the Actions API — so building/waiting counts are
    /// per-platform (and, where the labels are machine-unique like `pulp-build-m5`,
    /// per-machine) rather than a host-global VM count. Empty if not installed.
    func runnerLabels(fileManager: FileManager = .default) -> [String] {
        guard let data = fileManager.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let idx = args.firstIndex(of: "--labels"), idx + 1 < args.count
        else { return [] }
        return args[idx + 1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lanes this build of the app knows how to toggle — one row per platform.
    /// Each is opt-in/out independently, so you can serve macOS but not Linux,
    /// or pause any of them while you're working, without overwhelming the Mac.
    static var known: [CIServingLane] {
        [
            CIServingLane(
                id: "macos",
                platform: "macOS",
                agentLabel: "com.danielraffel.pulp.tart-runner",
                plistPath: agentPlist("com.danielraffel.pulp.tart-runner")
            ),
            CIServingLane(
                id: "linux",
                platform: "Linux",
                agentLabel: "com.danielraffel.pulp.tart-runner-linux",
                plistPath: agentPlist("com.danielraffel.pulp.tart-runner-linux")
            ),
            CIServingLane(
                id: "windows",
                platform: "Windows",
                agentLabel: "com.danielraffel.pulp.qemu-runner-windows",
                plistPath: agentPlist("com.danielraffel.pulp.qemu-runner-windows")
            ),
        ]
    }
}

/// Live status of a lane.
///
/// `building` and `waiting` are driven by the GitHub **runner** state for this
/// lane's labels (not a host-global VM count): a runner that's `busy` is
/// *running a job* (building); an `online`+idle runner is a warm VM *waiting*
/// for a job / overflow. That distinction is the green-vs-orange the UI shows —
/// a VM being merely *up* is NOT "building" (that's why the M5 could sit with an
/// idle VM for hours).
struct CIServingStatus: Equatable {
    /// The runner agent is installed on this Mac (plist present).
    var installed: Bool
    /// The agent is loaded → this Mac is in the pool, taking jobs.
    var serving: Bool
    /// Runners for this lane actively running a job right now (busy).
    var building: Int = 0
    /// Runners for this lane online + idle (warm, available for jobs/overflow).
    var waiting: Int = 0
    /// Toggling/loading in progress.
    var isToggling: Bool = false

    var isBuilding: Bool { building > 0 }
    var isWaiting: Bool { building == 0 && waiting > 0 }

    static let unknown = CIServingStatus(installed: false, serving: false)

    /// One-line human status for the row.
    var summary: String {
        if !installed { return "Not set up on this Mac" }
        if isToggling { return "Updating…" }
        if !serving { return "Not serving" }
        if building > 0 { return "Building \(building) job\(building == 1 ? "" : "s")" }
        if waiting > 0 { return "Waiting · \(waiting) ready" }
        return "Serving · idle"
    }
}

/// Aggregate runner state for the popover header — the *runner* signal, kept
/// deliberately SEPARATE from the connection/live-update signal (`statusDot`).
/// Sums across enabled lanes (each lane's runners are distinct), so the header
/// matches what the rows show: building (green) wins, else waiting (orange),
/// else serving-idle.
struct RunnerHeaderState: Equatable {
    enum Kind: Equatable { case none, off, updating, idle, waiting, building }
    let kind: Kind
    let count: Int

    /// Hidden entirely when no runner lane is installed on this Mac.
    var isVisible: Bool { kind != .none }

    var label: String {
        switch kind {
        case .none:     return ""
        case .off:      return "runner off"
        case .updating: return "updating…"
        case .idle:     return "serving"
        case .waiting:  return "waiting · \(count)"
        case .building: return "building · \(count)"
        }
    }

    /// Pure roll-up over the per-lane statuses (testable, no I/O).
    static func from(_ statuses: [CIServingStatus]) -> RunnerHeaderState {
        let installed = statuses.filter { $0.installed }
        guard !installed.isEmpty else { return RunnerHeaderState(kind: .none, count: 0) }
        // A toggle in flight (launchd loading/unloading) shows "updating…" so it
        // isn't briefly indistinguishable from "runner off".
        if installed.contains(where: { $0.isToggling }) {
            return RunnerHeaderState(kind: .updating, count: 0)
        }
        let serving = installed.filter { $0.serving }
        guard !serving.isEmpty else { return RunnerHeaderState(kind: .off, count: 0) }
        // Different lanes run on distinct runners, so SUM (not max).
        let building = serving.reduce(0) { $0 + $1.building }
        if building > 0 { return RunnerHeaderState(kind: .building, count: building) }
        let waiting = serving.reduce(0) { $0 + $1.waiting }
        if waiting > 0 { return RunnerHeaderState(kind: .waiting, count: waiting) }
        return RunnerHeaderState(kind: .idle, count: 0)
    }
}
