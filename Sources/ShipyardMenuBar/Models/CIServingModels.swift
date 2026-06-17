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
    let id: String           // stable key = the launchd label (unique per lane)
    let platform: String     // display name, e.g. "macOS · gate"
    let agentLabel: String   // launchd label
    let plistPath: String    // ~/Library/LaunchAgents/<label>.plist

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

    /// Lanes this build of the app knows how to toggle — one row per *installed*
    /// runner agent. Discovered from this host's own LaunchAgents (below), so any
    /// host shows its real runners (M1 = sanitizer, Studio = gate, …) instead of
    /// assuming the gate/linux/windows runners exist. Each is opt-in/out
    /// independently, so you can pause any of them while you're working.
    static var known: [CIServingLane] { discover() }

    /// A canonical runner agent label suffix: `tart-runner` or `qemu-runner`,
    /// optionally followed by hyphenated lane segments (`-linux`, `-macos-release`,
    /// `-sanitizer-macos`, …) — lowercase alphanumerics and hyphens only, NO dots.
    /// This is what excludes rotated backups that still end in `.plist` but inject a
    /// dot, e.g. `com.danielraffel.pulp.tart-runner.pre-20260609-phase4.plist`.
    static let runnerLabelSuffixPattern = "^(tart|qemu)-runner(-[a-z0-9]+)*$"

    /// Discover installed runner lanes by scanning `~/Library/LaunchAgents` for
    /// `com.danielraffel.pulp.<canonical-runner-label>.plist`. Sorted for stable order.
    static func discover(
        agentsDirectory: String = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents"),
        fileManager: FileManager = .default
    ) -> [CIServingLane] {
        guard let files = try? fileManager.contentsOfDirectory(atPath: agentsDirectory)
        else { return [] }
        let prefix = "com.danielraffel.pulp."
        return files
            .filter { filename in
                guard filename.hasPrefix(prefix) && filename.hasSuffix(".plist") else { return false }
                // The label between the prefix and `.plist` must be a CANONICAL runner
                // label — not a backup/rotated/disabled variant that happens to keep
                // the `.plist` extension (the real fleet has exactly such a backup).
                let suffix = String(filename.dropFirst(prefix.count).dropLast(".plist".count))
                guard suffix.range(of: runnerLabelSuffixPattern,
                                   options: [.regularExpression]) != nil else { return false }
                // Exclude a directory that merely happens to be named *.plist — it
                // would otherwise become a phantom "installed" lane with no labels.
                var isDir: ObjCBool = false
                let full = (agentsDirectory as NSString).appendingPathComponent(filename)
                return fileManager.fileExists(atPath: full, isDirectory: &isDir) && !isDir.boolValue
            }
            .map { filename in
                let label = String(filename.dropLast(".plist".count))
                return CIServingLane(
                    id: label,
                    platform: laneName(for: label),
                    agentLabel: label,
                    plistPath: (agentsDirectory as NSString).appendingPathComponent(filename))
            }
            .sorted { ($0.platform, $0.id) < ($1.platform, $1.id) }
    }

    /// Human lane name inferred from the agent label.
    static func laneName(for label: String) -> String {
        let suffix = label.replacingOccurrences(of: "com.danielraffel.pulp.", with: "")
        if suffix.contains("qemu") { return "Windows" }
        if suffix.contains("linux") { return "Linux" }
        if suffix.contains("sanitizer") { return "macOS · sanitizer" }
        if suffix.contains("coverage") { return "macOS · coverage" }
        if suffix.contains("release") { return "macOS · release" }
        // Name the plain gate runner so it's distinct from the other macOS lanes;
        // any other unknown macOS lane keeps its label suffix to avoid collisions.
        if suffix == "tart-runner" { return "macOS · gate" }
        return "macOS · \(suffix)"
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
