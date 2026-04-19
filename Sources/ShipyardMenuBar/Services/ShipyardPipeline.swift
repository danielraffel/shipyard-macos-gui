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

    /// Start polling for active ships and keep one watcher per PR.
    /// `onUpdate` is called on every NDJSON event from any watcher and
    /// is responsible for merging into UI state.
    ///
    /// Callback receives (pr, event). A nil event means the ship was
    /// discovered by ship-state list and we spawned a watcher for it.
    func start(onUpdate: @escaping @Sendable (Int, WatchEvent?) -> Void) {
        stop()
        discoveryTask = Task {
            while !Task.isCancelled {
                if let entries = await ShipStateListPoller.fetch(binary: self.binary) {
                    let knownPRs = Set(entries.map(\.pr))

                    // Reap watchers whose ships aren't in the list anymore.
                    for (pr, runner) in await self.snapshotWatchers() where !knownPRs.contains(pr) {
                        await runner.stop()
                        await self.forget(pr: pr)
                    }

                    // Spawn watchers for new PRs.
                    for entry in entries where await !self.hasWatcher(for: entry.pr) {
                        await self.spawnWatcher(for: entry.pr, onUpdate: onUpdate)
                        onUpdate(entry.pr, nil)
                    }
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            }
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        for runner in watchers.values { Task { await runner.stop() } }
        watchers.removeAll()
    }

    // MARK: - Internal

    private func hasWatcher(for pr: Int) -> Bool { watchers[pr] != nil }
    private func snapshotWatchers() -> [(Int, ShipyardCLIRunner)] { watchers.map { ($0.key, $0.value) } }
    private func forget(pr: Int) { watchers.removeValue(forKey: pr) }

    private func spawnWatcher(
        for pr: Int,
        onUpdate: @escaping @Sendable (Int, WatchEvent?) -> Void
    ) async {
        let runner = ShipyardCLIRunner(
            executable: binary,
            args: ["watch", "--pr", "\(pr)", "--json", "--follow"]
        )
        watchers[pr] = runner
        await runner.start { line in
            guard let data = line.data(using: .utf8) else { return }
            if let event = try? JSONDecoder.shipyard.decode(WatchEvent.self, from: data) {
                onUpdate(pr, event)
            }
        }
    }
}
