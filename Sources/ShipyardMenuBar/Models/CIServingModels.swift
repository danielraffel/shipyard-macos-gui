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
struct CIServingStatus: Equatable {
    /// The runner agent is installed on this Mac (plist present).
    var installed: Bool
    /// The agent is loaded → this Mac is in the pool, taking jobs.
    var serving: Bool
    /// How many build VMs are running right now (best-effort).
    var busyVMs: Int
    /// Toggling/loading in progress.
    var isToggling: Bool = false

    var isBusy: Bool { busyVMs > 0 }

    static let unknown = CIServingStatus(installed: false, serving: false, busyVMs: 0)

    /// One-line human status for the row.
    var summary: String {
        if !installed { return "Not set up on this Mac" }
        if isToggling { return "Updating…" }
        if !serving { return "Not serving" }
        // A running VM may be a WARM runner waiting for a job, not actively
        // building — so report the honest "N VM up" count rather than claiming
        // "building", which over-states what we actually know.
        guard isBusy else { return "Serving · idle" }
        return "Serving · \(busyVMs) VM\(busyVMs == 1 ? "" : "s") up"
    }
}

/// Aggregate runner state for the popover header — the *runner* signal, kept
/// deliberately SEPARATE from the connection/live-update signal (`statusDot`).
/// The header was conflating "is the app getting live data" with "is this Mac
/// serving CI"; this is the second, distinct indicator.
struct RunnerHeaderState: Equatable {
    enum Kind: Equatable { case none, off, updating, serving }
    let kind: Kind
    let runningVMs: Int

    /// Hidden entirely when no runner lane is installed on this Mac.
    var isVisible: Bool { kind != .none }

    var label: String {
        switch kind {
        case .none:     return ""
        case .off:      return "runner off"
        case .updating: return "updating…"
        case .serving:  return runningVMs > 0 ? "serving · \(runningVMs) up" : "serving"
        }
    }

    /// Pure roll-up over the per-lane statuses (testable, no I/O).
    /// `busyVMs` is a host-global count (same for every Tart-backed lane), so we
    /// take the max rather than summing to avoid double-counting one VM.
    static func from(_ statuses: [CIServingStatus]) -> RunnerHeaderState {
        let installed = statuses.filter { $0.installed }
        guard !installed.isEmpty else { return RunnerHeaderState(kind: .none, runningVMs: 0) }
        // A toggle in flight (launchd loading/unloading) shows "updating…" in the
        // header too, so it isn't briefly indistinguishable from "runner off".
        if installed.contains(where: { $0.isToggling }) {
            return RunnerHeaderState(kind: .updating, runningVMs: 0)
        }
        let serving = installed.filter { $0.serving }
        guard !serving.isEmpty else { return RunnerHeaderState(kind: .off, runningVMs: 0) }
        let vms = serving.map(\.busyVMs).max() ?? 0
        return RunnerHeaderState(kind: .serving, runningVMs: vms)
    }
}
