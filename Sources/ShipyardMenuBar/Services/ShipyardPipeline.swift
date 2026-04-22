import Foundation
import Combine

/// Coordinates ship discovery (ship-state list) with per-PR live tails
/// (shipyard watch --pr <n> --json --follow). Owns one `ShipyardCLIRunner`
/// per active ship and reaps them when a ship is merged/archived.
///
/// Owned by AppStore. All store mutations happen via the callback the
/// store passes in at `start(onUpdate:)`; this type itself is actor-isolated.
actor ShipyardPipeline {
    private let binary: String
    private var discoveryTask: Task<Void, Never>?
    private var watchers: [Int: ShipyardCLIRunner] = [:]

    init(binary: String) {
        self.binary = binary
    }

    /// Poll `shipyard ship-state list` for the authoritative ship snapshot.
    /// That one command returns everything we need (PR, repo, branch,
    /// dispatched_runs, evidence_snapshot) so we skip the per-PR watch
    /// subprocesses and avoid long-lived pipes. The tradeoff is coarse
    /// granularity (7s) vs real-time NDJSON — good enough for a
    /// glanceable menu bar.
    ///
    /// On startup we must ALWAYS drive the store past its
    /// `hasLoadedInitialShips == false` state so the view can stop
    /// showing a spinner. If the very first poll returns nil (binary
    /// exec failed, empty stdout, JSON decode failed — all collapse to
    /// nil silently inside the poller), the prior version discarded
    /// the nil and waited another 7s. That put the spinner on a
    /// forever-loop with no visible signal to the user. Now we emit
    /// an empty snapshot once after a short retry so the UI flips to
    /// the "no ships" empty-copy (which is at least truthful: we
    /// couldn't find any ships). Subsequent polls still refresh.
    func start(onSnapshot: @escaping @Sendable ([ShipStateListEntry]) -> Void) {
        stop()
        discoveryTask = Task {
            var sawFirstSnapshot = false
            while !Task.isCancelled {
                let fetched = await ShipStateListPoller.fetch(binary: self.binary)
                if let entries = fetched {
                    sawFirstSnapshot = true
                    onSnapshot(entries)
                } else if !sawFirstSnapshot {
                    // First poll failed. Retry after 1s before giving
                    // up on this cycle — transient subprocess hiccups
                    // (spawn race, hardened-runtime first-run prompt)
                    // often resolve on the second attempt.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let retry = await ShipStateListPoller.fetch(binary: self.binary)
                    if let entries = retry {
                        sawFirstSnapshot = true
                        onSnapshot(entries)
                    } else {
                        // Give up for the initial render — emit an
                        // empty snapshot so the store clears the
                        // initial-loading spinner. Regular 7s polls
                        // still retry; if a later poll succeeds the
                        // UI populates normally.
                        sawFirstSnapshot = true
                        onSnapshot([])
                    }
                }
                try? await Task.sleep(nanoseconds: 7_000_000_000) // 7s
            }
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        for runner in watchers.values { Task { await runner.stop() } }
        watchers.removeAll()
    }
}
