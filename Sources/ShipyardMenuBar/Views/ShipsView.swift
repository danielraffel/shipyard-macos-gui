import SwiftUI

struct ShipsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                rateLimitBanner
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

    /// Informational strip when the user's 5,000/hr GitHub REST budget
    /// is exhausted or near-exhausted. Polling data stops refreshing
    /// during the exhaustion window; webhooks still work. Banner tells
    /// the user the app will catch up automatically once the reset
    /// fires — no need to quit and restart.
    @ViewBuilder
    private var rateLimitBanner: some View {
        if let rl = store.githubRateLimit, rl.isExceeded || rl.isNearExhaustion {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: rl.isExceeded
                      ? "exclamationmark.triangle.fill"
                      : "clock.arrow.circlepath")
                    .foregroundStyle(rl.isExceeded ? .orange : .yellow)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(rl.isExceeded
                         ? "GitHub API rate limit exceeded"
                         : "GitHub API rate limit low")
                        .font(.system(size: 11, weight: .semibold))
                    Text(bannerDetail(for: rl))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill((rl.isExceeded ? Color.orange : Color.yellow).opacity(0.12))
            )
        }
    }

    private func bannerDetail(for rl: GitHubRateLimit) -> String {
        // Hand-rolled rather than RelativeDateTimeFormatter — the
        // latter yields "in 20 min." with a trailing period that
        // collides with our sentence-ending period ("20 min..").
        let relative = relativeBannerTime(until: rl.resetAt)
        let absolute = absoluteBannerTime(rl.resetAt)
        if rl.isExceeded {
            return "Polling paused until reset \(relative) at \(absolute). Live webhook updates still working. App will catch up automatically — no need to quit."
        }
        return "\(rl.remaining) of \(rl.limit) calls left. Resets \(relative) at \(absolute)."
    }

    private func relativeBannerTime(until date: Date) -> String {
        let seconds = Int(max(0, date.timeIntervalSinceNow))
        if seconds < 60 { return "in \(seconds) sec" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "in \(minutes) min" }
        let hours = Double(minutes) / 60.0
        if hours < 2 { return String(format: "in %.1f hr", hours) }
        return "in \(Int(hours)) hr"
    }

    private static let bannerTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private func absoluteBannerTime(_ date: Date) -> String {
        Self.bannerTimeFormatter.string(from: date)
    }

    private var scopeFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(scopeFooterText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 12)
        .padding(.horizontal, 4)
    }

    /// Footer text matches what the user actually sees: only mention
    /// "and recent GitHub Actions" when the unrelated-runs section is
    /// going to render. Otherwise it reads as a lie when the section
    /// is filtered to empty.
    private var scopeFooterText: String {
        guard store.showGitHubActions else {
            return "Tracked PRs you've shipped with Shipyard. Enable GitHub Actions in Settings to see more."
        }
        let hasUnrelated = !store.unrelatedGitHubRuns().isEmpty
        if hasUnrelated {
            return "Tracked PRs you've shipped with Shipyard and recent GitHub Actions."
        }
        return "Tracked PRs you've shipped with Shipyard."
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
        visibleShips.filter { ship in
            // Terminal at the shipyard level…
            if ship.overallStatus == .passed || ship.overallStatus == .failed {
                return true
            }
            // …or the PR has been closed/merged on github.com even
            // if the local ship-state thinks it's still pending.
            if let pr = store.prState(for: ship), pr.isClosed {
                return true
            }
            return false
        }.count
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            // Literal uppercase (not .textCase) so "PRs" stays with a
            // lowercase final "s" — textCase(.uppercase) would render
            // "PRS" which reads oddly.
            Text("TRACKED PRs")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("· \(visibleShips.count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            overflowMenu
        }
        .padding(.vertical, 4)
    }

    /// Single overflow menu (ellipsis) replacing the chevron buttons
    /// and inline "Clear" / "Show hidden" links. Keeps the header
    /// clean on narrow popover widths and shows labels for every
    /// action so nothing is a mystery icon.
    private var overflowMenu: some View {
        Menu {
            Button {
                store.setAllExpanded(true)
            } label: {
                Label("Expand all cards", systemImage: "chevron.down.2")
            }
            Button {
                store.setAllExpanded(false)
            } label: {
                Label("Collapse all cards", systemImage: "chevron.up.2")
            }
            if store.hiddenCount > 0 {
                Divider()
                Button {
                    store.restoreAllHidden()
                } label: {
                    Label("Show \(store.hiddenCount) hidden", systemImage: "eye")
                }
            }
            if completedCount > 0 {
                Divider()
                Button {
                    store.clearCompleted()
                } label: {
                    Label("Clear \(completedCount) completed", systemImage: "sparkles")
                }
            }
            let visibleCount = store.ships.filter { !$0.dismissed }.count
            if visibleCount > 0 {
                if completedCount == 0 { Divider() }
                Button(role: .destructive) {
                    store.clearAll()
                } label: {
                    Label("Clear all \(visibleCount)", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("List actions")
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
            .help("Show every PR the CLI is tracking")
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
                Image(systemName: cadenceIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(cadenceLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
        }
    }

    private var cadenceIcon: String {
        if case .live = store.liveStatus { return "dot.radiowaves.left.and.right" }
        return "arrow.clockwise"
    }

    private var cadenceLabel: String {
        if case .live = store.liveStatus { return "Live via Tailscale Funnel" }
        return "Polling every 60s"
    }
}
