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
    /// showing a spinner. Two distinct problems we're solving:
    ///
    ///   (1) The shipyard CLI is a PyInstaller onefile binary that
    ///       cold-starts in 5-6s per invocation. A user who opens the
    ///       menu bar sees a "Loading PRs…" spinner for that window
    ///       every time. Emit an empty snapshot IMMEDIATELY on start
    ///       so the UI flips to its "no active PRs" state in a tick;
    ///       the real snapshot replaces it whenever the first fetch
    ///       returns. Brief flicker (empty → ships) is preferable to
    ///       a 5s spinner that looks like the app is broken.
    ///
    ///   (2) If the poller never returns non-nil (binary exec failed,
    ///       empty stdout, JSON decode failed — all collapse to nil
    ///       silently inside ShipStateListPoller.fetch), the prior
    ///       version discarded the nil and waited another 7s. That
    ///       put the spinner on a forever-loop. Firing the immediate
    ///       empty snapshot resolves that case too: we've flipped
    ///       hasLoadedInitialShips=true, so subsequent failures don't
    ///       re-strand the user on the loading screen.
    func start(onSnapshot: @escaping @Sendable ([ShipStateListEntry]) -> Void) {
        stop()
        // Fire the empty snapshot before the first fetch so the
        // spinner clears within milliseconds of app launch.
        onSnapshot([])
        discoveryTask = Task {
            while !Task.isCancelled {
                if let entries = await ShipStateListPoller.fetch(binary: self.binary) {
                    onSnapshot(entries)
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
