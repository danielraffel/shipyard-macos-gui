import SwiftUI

/// Rendered below the ship cards. Lists recent GitHub Actions runs per
/// repo the app has seen ship-states for, scoped by the Settings →
/// "Time window" and "Hide workflows matching" filters.
struct GitHubActionsSection: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let groups = store.unrelatedGitHubRuns()
        if store.showGitHubActions && !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                ForEach(groups.keys.sorted(), id: \.self) { repo in
                    repoGroup(repo: repo, runs: groups[repo] ?? [])
                }
            }
            .padding(.top, 12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("Other GitHub Actions runs")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("last \(windowLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text("Runs without a matching local ship-state — main/tag workflows, scheduled jobs, manual dispatches, and PRs you haven't shipped from this machine.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var windowLabel: String {
        switch store.ghWindowMinutes {
        case 60: return "1h"
        case 240: return "4h"
        case 1440: return "1d"
        case 10080: return "7d"
        default: return "\(store.ghWindowMinutes)m"
        }
    }

    @ViewBuilder
    private func repoGroup(repo: String, runs: [GitHubRun]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repo)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            VStack(spacing: 0) {
                ForEach(runs) { run in
                    GitHubRunRow(run: run, compact: false)
                    if run != runs.last {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
    }
}
