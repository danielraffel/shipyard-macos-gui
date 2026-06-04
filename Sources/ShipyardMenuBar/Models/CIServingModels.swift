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
        return isBusy ? "Serving · building (\(busyVMs))" : "Serving · idle"
    }
}
