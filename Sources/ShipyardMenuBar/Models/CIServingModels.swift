import Foundation

/// A CI "lane" this Mac can serve — i.e. a self-hosted runner for one platform,
/// backed by a launchd agent that picks up jobs and runs each in a throwaway VM.
///
/// v1 ships a single macOS lane (the Tart runner installed by pulp's
/// `tools/ci/setup-ci-host.sh`). The list shape is deliberate so Linux/Windows
/// lanes can be added later as extra rows with no UI redesign.
struct CIServingLane: Identifiable, Equatable {
    let id: String           // stable key, e.g. "macos"
    let platform: String     // display name, e.g. "macOS"
    let agentLabel: String   // launchd label
    let plistPath: String    // ~/Library/LaunchAgents/<label>.plist

    /// Lanes this build of the app knows how to toggle. Today: just macOS.
    static var known: [CIServingLane] {
        [
            CIServingLane(
                id: "macos",
                platform: "macOS",
                agentLabel: "com.danielraffel.pulp.tart-runner",
                plistPath: (NSHomeDirectory() as NSString)
                    .appendingPathComponent(
                        "Library/LaunchAgents/com.danielraffel.pulp.tart-runner.plist")
            )
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
