import SwiftUI

/// Rendered above the tracked PR cards. Lists recent GitHub Actions
/// workflow runs that do not match a local Shipyard card. This is not
/// a PR list and intentionally uses the existing Actions polling path
/// instead of adding `gh pr list` calls.
struct GitHubActionsSection: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        // Tallies in the header are grouping-independent, so key them off the
        // repo grouping; the body renders whatever grouping the user picked.
        let byRepo = store.unrelatedGitHubRuns()
        if store.showGitHubActions && !byRepo.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                collapsibleHeader(groups: byRepo)
                if store.otherActionsExpanded {
                    groupingPicker
                    ForEach(store.groupedGitHubRuns(), id: \.key) { group in
                        repoGroup(repo: group.key, runs: group.runs)
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    /// All / by-machine / by-runner selector for the runs below.
    private var groupingPicker: some View {
        Picker("", selection: $store.ghGrouping) {
            ForEach(AppStore.GHGrouping.allCases) { g in
                Text(g.label).tag(g)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.bottom, 2)
        .help("Group runs by repository (All), by the Mac that ran them, or by the specific runner.")
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
                    Text("GitHub Actions not tracked by Shipyard")
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
        .help("Runs from the existing gh run list cache that do not match local Shipyard ship-state by branch or SHA. No extra gh pr list calls are made.")
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
