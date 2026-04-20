import SwiftUI

struct ShipsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if store.ships.isEmpty {
                    emptyState
                } else {
                    ActivitySummaryStrip()
                    headerBar
                    if store.groupByWorktree {
                        groupedView
                    } else {
                        ForEach(visibleShips) { ship in
                            ShipCardView(ship: ship)
                        }
                    }
                    GitHubActionsSection()
                    scopeFooter
                }
            }
            .padding(12)
        }
    }

    private var scopeFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(store.showGitHubActions
                 ? "Ship cards: local dispatches. Below: recent GitHub Actions for the same repos."
                 : "Showing local ship-state only. Enable GitHub Actions in Settings to see more.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 12)
        .padding(.horizontal, 4)
    }

    private var groupedView: some View {
        let groups = Dictionary(grouping: visibleShips) { $0.worktree.isEmpty ? "—" : $0.worktree }
        let sortedKeys = groups.keys.sorted()
        return ForEach(sortedKeys, id: \.self) { key in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(key)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Text("\(groups[key]?.count ?? 0)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                ForEach(groups[key] ?? []) { ship in
                    ShipCardView(ship: ship)
                }
            }
        }
    }

    private var visibleShips: [Ship] {
        store.ships.filter { !$0.dismissed }
    }

    private var completedCount: Int {
        visibleShips.filter {
            $0.overallStatus == .passed || $0.overallStatus == .failed
        }.count
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("Local ship-states")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("· \(visibleShips.count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            if completedCount > 0 {
                Button("Clear \(completedCount) completed") {
                    store.clearCompleted()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.blue)
                .help("Remove all passed and failed ships from the list")
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "anchor")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .padding(.top, 60)
            if store.hiddenStaleCount > 0 && store.cliBinaryResolved != nil {
                hiddenStaleBlock
            } else if store.cliBinaryResolved == nil {
                cliMissingBlock
            } else {
                nothingInFlightBlock
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hiddenStaleBlock: some View {
        VStack(spacing: 4) {
            Text("Nothing in flight")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(store.hiddenStaleCount) completed state\(store.hiddenStaleCount == 1 ? "" : "s") hidden by auto-clear.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text("The CLI retains finished ships past the auto-clear interval. None are actively running.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                store.showStale = true
                store.restartPipelineIfPossible()
            } label: {
                Text("Show all \(store.hiddenStaleCount)")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 6)
            .help("Show every ship-state entry the CLI is tracking")
        }
    }

    private var cliMissingBlock: some View {
        VStack(spacing: 8) {
            Text("Shipyard CLI not found")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("This app is a companion to the Shipyard CLI. Install it, then point to the binary in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            Link(destination: URL(string: "https://github.com/danielraffel/Shipyard#installation")!) {
                HStack(spacing: 4) {
                    Text("Install instructions")
                    Image(systemName: "arrow.up.forward.app")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.top, 4)
        }
    }

    private var nothingInFlightBlock: some View {
        VStack(spacing: 4) {
            Text("Nothing in flight")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Run \u{201C}shipyard ship\u{201D} in a worktree to see progress here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("Polling every 7s")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
        }
    }
}
