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
                collapsibleHeader(groups: groups)
                if store.otherActionsExpanded {
                    ForEach(groups.keys.sorted(), id: \.self) { repo in
                        repoGroup(repo: repo, runs: groups[repo] ?? [])
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private func collapsibleHeader(groups: [String: [GitHubRun]]) -> some View {
        let counts = tallies(groups: groups)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                store.otherActionsExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: store.otherActionsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
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
                HStack(spacing: 10) {
                    tally(label: "\(counts.running) running",
                          color: ShipyardColors.blue,
                          show: counts.running > 0)
                    tally(label: "\(counts.failed) failed",
                          color: ShipyardColors.red,
                          show: counts.failed > 0)
                    tally(label: "\(counts.succeeded) green",
                          color: ShipyardColors.green,
                          show: counts.succeeded > 0)
                    if counts.running == 0 && counts.failed == 0 && counts.succeeded == 0 {
                        Text("\(counts.total) run\(counts.total == 1 ? "" : "s") — click to expand")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 24)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Runs that don't match a PR you've shipped from this machine — main/tag workflows, scheduled jobs, manual dispatches, and other contributors' PRs.")
    }

    @ViewBuilder
    private func tally(label: String, color: Color, show: Bool) -> some View {
        if show {
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct Tallies {
        var running: Int = 0
        var failed: Int = 0
        var succeeded: Int = 0
        var total: Int { running + failed + succeeded }
    }

    private func tallies(groups: [String: [GitHubRun]]) -> Tallies {
        var t = Tallies()
        for runs in groups.values {
            for run in runs {
                if run.isRunning { t.running += 1 }
                else if run.isFailure { t.failed += 1 }
                else if run.conclusion == "success" { t.succeeded += 1 }
            }
        }
        return t
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
