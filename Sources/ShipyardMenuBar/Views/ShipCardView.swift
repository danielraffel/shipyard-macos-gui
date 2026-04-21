import SwiftUI

struct ShipCardView: View {
    let ship: Ship
    @EnvironmentObject var store: AppStore
    @State private var expanded: Bool
    @State private var hovering: Bool = false
    @State private var addLaneOpen: Bool = false

    init(ship: Ship) {
        self.ship = ship
        // Default expanded when there's content: either shipyard
        // target rows OR nested GitHub Actions runs for this PR.
        // We can't read the store here, so .onAppear re-syncs both
        // expand-all state and the "has activity" signal.
        self._expanded = State(initialValue: !ship.targets.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded {
                if ship.targets.isEmpty {
                    emptyTargetsRow
                } else {
                    ForEach(ship.targets) { target in
                        TargetRowView(target: target, ship: ship)
                    }
                }
                let ghRuns = store.githubRuns(for: ship)
                if !ghRuns.isEmpty {
                    nestedGitHubRuns(ghRuns)
                }
                if addLaneOpen {
                    AddLaneView(
                        ship: ship,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.18)) { addLaneOpen = false }
                        }
                    )
                }
                footer
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
        )
        .onHover { hovering = $0 }
        .onAppear {
            // Kick off branch-scoped fetch + PR state fetch on first
            // render. These populate data the rest of the card reads.
            store.fetchRunsForShipOnDemand(ship)
            store.fetchPRStateIfNeeded(for: ship)
            // Honour the user's most-recent expand-all / collapse-all
            // action if they pressed it BEFORE this card scrolled into
            // view (LazyVStack defers creation, so .onChange wouldn't
            // fire for off-screen cards).
            if store.expandAllTick > 0 {
                expanded = store.expandAllState
            } else if ship.targets.isEmpty && !store.githubRuns(for: ship).isEmpty {
                expanded = true
            }
        }
        .onChange(of: expanded) { nowExpanded in
            // macOS 13 signature. Re-fetch on expand — user is asking
            // to see detail, make sure the nested section is current.
            if nowExpanded {
                store.fetchRunsForShipOnDemand(ship)
            }
        }
        .onChange(of: store.expandAllTick) { _ in
            expanded = store.expandAllState
        }
    }

    @ViewBuilder
    private func nestedGitHubRuns(_ runs: [GitHubRun]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("GitHub Actions on this PR")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
            .padding(.top, 6)
            ForEach(runs) { run in
                GitHubRunRow(run: run, compact: true)
            }
        }
    }

    private var emptyTargetsRow: some View {
        let hasGH = !store.githubRuns(for: ship).isEmpty
        return HStack(spacing: 6) {
            Image(systemName: hasGH ? "bolt.circle" : "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(hasGH
                     ? "CI running on GitHub Actions"
                     : "No local dispatch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(hasGH
                     ? "Shipyard pushed the branch; GitHub Actions picked up CI on its own via push triggers. See the runs below."
                     : "`shipyard ship` recorded this state but didn't dispatch any targets locally — and no GitHub Actions runs have arrived yet for this branch.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Expand/collapse zone: chevron + repo + PR + branch all toggle.
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                if !ship.repo.isEmpty {
                    Text(ship.repo)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(2)
                        .help(tooltip(for: ship))
                    Text("·").foregroundStyle(.tertiary)
                }

                // PR number is a separate link so users can still click
                // through to GitHub without triggering the expand.
                Link(destination: prURL) {
                    Text("#\(ship.prNumber)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .onTapGesture { /* absorbs the tap, preventing header toggle */ }
                .help("Open PR #\(ship.prNumber) on GitHub")
                .layoutPriority(3)

                if !ship.branch.isEmpty {
                    Text(ship.branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                        .help(tooltip(for: ship))
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }

            // Count-badge for nested GitHub Actions runs. Visible in
            // collapsed state so users know there IS something in this
            // card before they expand it.
            if !expanded {
                let ghCount = store.githubRuns(for: ship).count
                if ghCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundStyle(ShipyardColors.blue)
                        Text("\(ghCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ShipyardColors.blue)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ShipyardColors.blue.opacity(0.12), in: Capsule())
                    .help("\(ghCount) GitHub Actions run\(ghCount == 1 ? "" : "s") on this PR — click the card header to expand.")
                }
            }

            statusPill

            // Archive button — available for any terminal or empty-runs
            // ship. Calls `shipyard ship-state discard <pr>` under the
            // hood so the CLI forgets the state too, not just the UI.
            if ship.overallStatus == .passed
               || ship.overallStatus == .failed
               || ship.targets.isEmpty {
                Button {
                    store.archive(ship: ship)
                } label: {
                    Image(systemName: "archivebox.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Archive this ship-state (calls `shipyard ship-state discard \(ship.prNumber)`)")
                .opacity(hovering ? 1 : 0.4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !ship.worktree.isEmpty && !store.groupByWorktree {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(ship.worktree)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { addLaneOpen.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                    Text("Add lane")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Add a new target lane to this in-flight ship")

            Toggle(isOn: Binding(
                get: { ship.autoMerge },
                set: { _ in store.toggleAutoMerge(for: ship) }
            )) {
                Text("auto-merge")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Merge automatically when all required lanes are green")
            if ship.overallStatus == .running {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(relative(ship.startedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    private var statusPill: some View {
        // PR state on github.com is the authoritative "is this PR
        // actually active?" signal. Check it first — a merged/closed
        // PR should never show "running" or "awaiting CI" regardless
        // of what the local ship-state says.
        let prState = store.prState(for: ship)
        let label: String
        let color: Color
        let icon: String?

        if let prState, prState.isMerged {
            label = "merged"; color = ShipyardColors.purple
            icon = "arrow.trianglehead.merge"
        } else if let prState, prState.isClosed {
            label = "closed"; color = .secondary; icon = "xmark.circle"
        } else {
            // Open (or unknown) PR — derive from shipyard + GH runs.
            let effective: TargetStatus = {
                if ship.targets.isEmpty,
                   let derived = store.derivedStatusFromGitHub(for: ship) {
                    return derived
                }
                return ship.overallStatus
            }()
            switch effective {
            case .passed:
                label = "green"; color = ShipyardColors.green
                icon = "arrow.trianglehead.merge"
            case .failed:
                label = "failed"; color = ShipyardColors.red; icon = nil
            case .running:
                label = "running"; color = ShipyardColors.blue; icon = nil
            case .reused:
                label = "reused"; color = ShipyardColors.purple; icon = nil
            case .skipped:
                label = "skipped"; color = .secondary; icon = nil
            case .pending:
                if ship.targets.isEmpty {
                    label = "awaiting CI"; color = .secondary; icon = nil
                } else {
                    label = "queued"; color = .secondary; icon = nil
                }
            }
        }
        return HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var prURL: URL {
        guard !ship.repo.isEmpty else {
            return URL(string: "https://github.com")!
        }
        return URL(string: "https://github.com/\(ship.repo)/pull/\(ship.prNumber)")
            ?? URL(string: "https://github.com")!
    }

    /// Full-fidelity text for tooltip on header fields. We build one
    /// tooltip that covers repo + branch + worktree so hovering any of
    /// them gives the complete context.
    private func tooltip(for ship: Ship) -> String {
        var lines: [String] = []
        if !ship.repo.isEmpty { lines.append("Repo: \(ship.repo)") }
        lines.append("PR: #\(ship.prNumber)")
        if !ship.branch.isEmpty { lines.append("Branch: \(ship.branch)") }
        if !ship.worktree.isEmpty { lines.append("Worktree: \(ship.worktree)") }
        if !ship.headSha.isEmpty { lines.append("HEAD: \(String(ship.headSha.prefix(12)))") }
        return lines.joined(separator: "\n")
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
