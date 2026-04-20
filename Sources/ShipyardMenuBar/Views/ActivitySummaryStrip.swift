import SwiftUI

/// One-line summary at the top of the Runners view answering
/// "what's actually happening right now?". Counts across both
/// Shipyard dispatched_runs AND GitHub Actions runs.
struct ActivitySummaryStrip: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let stats = computeStats()
        if stats.totalActive == 0 && stats.totalCompleted == 0 {
            EmptyView()
        } else {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if stats.shipyardRunning > 0 {
                    stat(icon: "circle.fill",
                         tint: ShipyardColors.blue,
                         text: "\(stats.shipyardRunning) dispatching")
                }
                if stats.ghRunning > 0 {
                    stat(icon: "bolt.circle.fill",
                         tint: ShipyardColors.blue,
                         text: "\(stats.ghRunning) on GitHub")
                }
                if stats.ghCompleted > 0 {
                    stat(icon: "checkmark.circle.fill",
                         tint: ShipyardColors.green,
                         text: "\(stats.ghCompleted) green")
                }
                if stats.ghFailed > 0 {
                    stat(icon: "xmark.circle.fill",
                         tint: ShipyardColors.red,
                         text: "\(stats.ghFailed) failed")
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.background.opacity(0.4))
            )
        }
    }

    private func stat(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private struct Stats {
        var shipyardRunning: Int = 0
        var ghRunning: Int = 0
        var ghCompleted: Int = 0
        var ghFailed: Int = 0
        var totalActive: Int { shipyardRunning + ghRunning }
        var totalCompleted: Int { ghCompleted + ghFailed }
    }

    private func computeStats() -> Stats {
        var s = Stats()
        for ship in store.ships where !ship.dismissed {
            for target in ship.targets where target.status == .running {
                s.shipyardRunning += 1
            }
        }
        // Count GH runs across the whole visible scope (both nested
        // under ships + unrelated), de-duped by id.
        var seen: Set<Int64> = []
        for ship in store.ships where !ship.dismissed {
            for run in store.githubRuns(for: ship) where seen.insert(run.id).inserted {
                if run.isRunning { s.ghRunning += 1 }
                else if run.isFailure { s.ghFailed += 1 }
                else if run.conclusion == "success" { s.ghCompleted += 1 }
            }
        }
        for (_, runs) in store.unrelatedGitHubRuns() {
            for run in runs where seen.insert(run.id).inserted {
                if run.isRunning { s.ghRunning += 1 }
                else if run.isFailure { s.ghFailed += 1 }
                else if run.conclusion == "success" { s.ghCompleted += 1 }
            }
        }
        return s
    }
}
