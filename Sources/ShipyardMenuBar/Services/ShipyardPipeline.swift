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
    func start(onSnapshot: @escaping @Sendable ([ShipStateListEntry]) -> Void) {
        stop()
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
