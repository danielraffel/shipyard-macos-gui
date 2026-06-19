import SwiftUI

struct ShipsView: View {
    @EnvironmentObject var store: AppStore
    /// Local flag so tapping "Show all N" gives immediate
    /// ProgressView feedback while the pipeline re-polls. Reset when
    /// ships actually appear (see .onChange below).
    @State private var isRestoring: Bool = false
    /// Expanded fleet PR rows (by FleetPR.id) — shows that Mac's last-known lanes.
    @State private var expandedFleetPRs: Set<String> = []
    /// Drives auto-refresh of the fleet view while it's on screen. Fires only when
    /// a remote filter is selected (showFleetView), so the popover-open case keeps
    /// the other Macs' PRs current without any GitHub API calls — the pull is the
    /// quota-free SSH ship-state fetch.
    private let fleetAutoRefresh = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                rateLimitBanner
                if store.ships.isEmpty && !showFleetView {
                    emptyState
                } else {
                    ActivitySummaryStrip()
                    NamespaceActivitySection()
                    headerBar
                    machineFilterBar
                    if showFleetView {
                        fleetPRsView
                            .onReceive(fleetAutoRefresh) { _ in
                                // Only while a remote filter is showing — keeps the
                                // other Macs' rows fresh without growing GitHub quota.
                                if showFleetView { store.refreshFleetPRs() }
                            }
                    } else {
                        trackedPRGroupsView
                    }
                    GitHubActionsSection()
                    scopeFooter
                }
            }
            .padding(12)
        }
        // Reset the "loading" state the moment ships actually show up.
        // Without this the spinner would spin forever — `isRestoring`
        // is a local flag with no other reset path. Using the macOS
        // 13-compatible single-arg form (iOS 17 / macOS 14 widened
        // the API to include old/new tuple).
        .onChange(of: store.ships.count) { newCount in
            if newCount > 0 {
                isRestoring = false
            }
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
            return "Tracked PRs from this machine. Enable GitHub Actions in Settings to see more."
        }
        let hasUnrelated = !store.unrelatedGitHubRuns().isEmpty
        if hasUnrelated {
            return "Tracked PRs from this machine, recent GitHub Actions, and active Namespace instances."
        }
        if !store.visibleNamespaceInstances().isEmpty {
            return "Tracked PRs from this machine and active Namespace instances."
        }
        return "Tracked PRs from this machine."
    }

    private var trackedPRGroupsView: some View {
        let groups = Dictionary(grouping: visibleShips) { ship in
            ship.repo.isEmpty ? "unknown repo" : ship.repo
        }
        let sortedRepos = groups.keys.sorted()
        return ForEach(sortedRepos, id: \.self) { repo in
            repoGroup(repo: repo, ships: groups[repo] ?? [])
        }
    }

    // MARK: - Fleet PR filter (This Mac / All / per-machine)

    /// Machine selector — only shown when remote fleet hosts are configured
    /// (~/.config/shipyard/fleet-hosts.json). "This Mac" keeps the rich local
    /// cards; All / a machine shows that Mac's tracked PRs (read-only, no GitHub
    /// calls). Switching to a remote view kicks a quota-free SSH ship-state pull.
    @ViewBuilder
    private var machineFilterBar: some View {
        let names = store.fleetMachineNames
        if !names.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("", selection: $store.prMachineFilter) {
                    Text(AppStore.thisMacFilter).tag(AppStore.thisMacFilter)
                    Text(AppStore.allMacsFilter).tag(AppStore.allMacsFilter)
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                Spacer()
                if store.prMachineFilter != AppStore.thisMacFilter {
                    let n = fleetPRsForFilter.count
                    Text("\(n) PR\(n == 1 ? "" : "s") · no API calls")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .help("See PRs tracked by other Macs in the pool. Read from each Mac's local Shipyard over Tailscale — never the GitHub API, so it costs no rate-limit budget.")
            .onAppear {
                // Snap a stale persisted filter (a machine no longer in the config)
                // back to This Mac so the picker never shows a blank selection.
                let valid = Set([AppStore.thisMacFilter, AppStore.allMacsFilter] + names)
                if !valid.contains(store.prMachineFilter) { store.prMachineFilter = AppStore.thisMacFilter }
                if store.prMachineFilter != AppStore.thisMacFilter { store.refreshFleetPRs() }
            }
        }
    }

    /// Local ships presented in the uniform fleet shape so "All" can list this
    /// Mac alongside the remotes.
    private func fleetStatus(_ t: TargetStatus) -> FleetPR.Status {
        switch t {
        case .failed: return .failed
        case .passed, .reused, .skipped: return .passed
        default: return .pending
        }
    }

    private var localShipsAsFleetPRs: [FleetPR] {
        visibleShips.map { ship in
            let lanes = ship.targets.map {
                FleetPR.Lane(target: $0.name, result: fleetStatus($0.status), phase: nil)
            }
            let status: FleetPR.Status
            switch ship.overallStatus {
            case .failed: status = .failed
            case .passed: status = .passed
            default: status = .pending
            }
            return FleetPR(machine: AppStore.thisMacFilter, repo: ship.repo,
                           prNumber: ship.prNumber, title: ship.prTitle,
                           branch: ship.branch, prURL: nil, status: status, lanes: lanes)
        }
    }

    /// Show the fleet view only when remote hosts exist AND a non-local filter is
    /// chosen. Guards the stuck state where a persisted remote filter + a removed
    /// hosts config would otherwise hide the local cards with no way back.
    private var showFleetView: Bool {
        !store.fleetMachineNames.isEmpty && store.prMachineFilter != AppStore.thisMacFilter
    }

    private var fleetPRsForFilter: [FleetPR] {
        switch store.prMachineFilter {
        case AppStore.thisMacFilter: return []
        case AppStore.allMacsFilter: return localShipsAsFleetPRs + store.fleetPRs
        case let machine: return store.fleetPRs.filter { $0.machine == machine }
        }
    }

    @ViewBuilder
    private var fleetPRsView: some View {
        let prs = fleetPRsForFilter
        if prs.isEmpty {
            Text(store.fleetPRs.isEmpty
                 ? "Fetching over Tailscale… (or that Mac is offline / has no tracked PRs)."
                 : "No tracked PRs for this selection.")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 4)
        } else {
            let byMachine = Dictionary(grouping: prs, by: \.machine)
            ForEach(byMachine.keys.sorted(), id: \.self) { machine in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(machine).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(byMachine[machine]?.count ?? 0)")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 4).padding(.top, 4)
                    ForEach((byMachine[machine] ?? []).sorted {
                        ($0.repo, $0.prNumber) < ($1.repo, $1.prNumber)
                    }) { pr in
                        fleetPRRow(pr)
                    }
                }
            }
        }
    }

    private func fleetStatusColor(_ s: FleetPR.Status) -> Color {
        switch s {
        case .passed: return ShipyardColors.green
        case .failed: return ShipyardColors.red
        case .pending: return .secondary
        }
    }

    private func fleetStatusLabel(_ s: FleetPR.Status) -> String {
        switch s {
        case .passed: return "passed"
        case .failed: return "failed"
        case .pending: return "awaiting"
        }
    }

    private func fleetPRRow(_ pr: FleetPR) -> some View {
        let isExpanded = expandedFleetPRs.contains(pr.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                // Chevron expands to the last-known lanes (no API call). Disabled
                // when the remote ship-state recorded no lanes for this PR.
                Button {
                    if isExpanded { expandedFleetPRs.remove(pr.id) }
                    else { expandedFleetPRs.insert(pr.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(pr.lanes.isEmpty ? .quaternary : .secondary)
                        .frame(width: 12, alignment: .center).padding(.top, 2)
                }
                .buttonStyle(.plain).disabled(pr.lanes.isEmpty)
                Circle().fill(fleetStatusColor(pr.status))
                    .frame(width: 6, height: 6).padding(.top, 4)
                Text("#\(pr.prNumber)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.blue)
                    .lineLimit(1).fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title.isEmpty ? pr.branch : pr.title)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(pr.repo)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if pr.prURL != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 1)
                }
            }
            if isExpanded && !pr.lanes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(pr.lanes) { lane in
                        HStack(spacing: 6) {
                            Circle().fill(fleetStatusColor(lane.result)).frame(width: 5, height: 5)
                            Text(lane.target).font(.system(size: 10, weight: .medium))
                            if let ph = lane.phase, !ph.isEmpty {
                                Text(ph).font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 4)
                            Text(fleetStatusLabel(lane.result))
                                .font(.system(size: 9)).foregroundStyle(fleetStatusColor(lane.result))
                        }
                    }
                    Text("last-known from \(pr.machine)'s ship-state · no API call")
                        .font(.system(size: 8)).foregroundStyle(.quaternary).padding(.top, 1)
                }
                .padding(.leading, 25).padding(.top, 7)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 0.5))
        )
        .contentShape(Rectangle())
        // Tap the row body to open the PR (chevron handles expand). Honors the
        // "close on link open" setting via store.openLink.
        .onTapGesture {
            if let u = pr.prURL, let url = URL(string: u) { store.openLink(url) }
        }
        .help("\(pr.repo) #\(pr.prNumber) · \(fleetStatusLabel(pr.status))\n\(pr.title.isEmpty ? pr.branch : pr.title)\nbranch: \(pr.branch)\(pr.lanes.isEmpty ? "" : "\nexpand ▸ for last-known lanes")\(pr.prURL != nil ? "\nclick to open on GitHub" : "")")
    }

    private func repoGroup(repo: String, ships: [Ship]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(repo)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(ships.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            if store.groupByWorktree {
                worktreeGroups(for: ships)
            } else {
                ForEach(ships) { ship in
                    ShipCardView(ship: ship)
                }
            }
        }
    }

    private func worktreeGroups(for ships: [Ship]) -> some View {
        let groups = Dictionary(grouping: ships) { $0.worktree.isEmpty ? "—" : $0.worktree }
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

    /// Shown on cold launch for the ~1-2s before the pipeline returns
    /// its first ship-state snapshot. Without this the user sees the
    /// "No active PRs" anchor + copy and assumes nothing's tracked —
    /// even though we're still loading.
    private var initialLoadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .padding(.top, 60)
            Text("Loading PRs…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            // Three exclusive states — one and only one can render.
            // The prior version had two sibling if/else blocks (spinner
            // OR anchor / then one of three copy blocks), which let the
            // "Loading PRs…" spinner coexist with the "No active PRs /
            // Run shipyard pr" empty-state copy. A reader saw both at
            // once and couldn't tell whether the app was still fetching
            // or had finished with nothing.
            if !store.hasLoadedInitialShips && store.cliBinaryResolved != nil {
                initialLoadingState
                    .transition(.opacity)
            } else if store.cliBinaryResolved == nil {
                VStack(spacing: 10) {
                    Image(systemName: "anchor")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 60)
                    cliMissingBlock
                }
                .transition(.opacity)
            } else if store.hiddenStaleCount > 0 {
                VStack(spacing: 10) {
                    Image(systemName: "anchor")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 60)
                    hiddenStaleBlock
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "anchor")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 60)
                    nothingInFlightBlock
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hiddenStaleBlock: some View {
        VStack(spacing: 4) {
            Text("No active PRs")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(store.hiddenStaleCount) completed state\(store.hiddenStaleCount == 1 ? "" : "s") hidden by auto-clear.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text("The CLI retains completed PRs past the auto-clear interval. None are actively running.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            // Restore is semi-async — restartPipelineIfPossible kicks a
            // fresh `shipyard ship-state list` poll which can take a
            // couple seconds before ships populate. Without immediate
            // feedback the tap feels lost: the old empty-state sits
            // there silently, then PRs pop in. Local `isRestoring`
            // flag shows a ProgressView the moment the button's hit
            // so the user knows the tap registered.
            Button {
                isRestoring = true
                store.showStale = true
                store.restartPipelineIfPossible()
            } label: {
                HStack(spacing: 6) {
                    if isRestoring {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading…")
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        Text("Show all \(store.hiddenStaleCount)")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 6)
            .disabled(isRestoring)
            .help("Show every PR the CLI is tracking")
        }
        // Empty-state transitions out with a gentle fade as ships load
        // in. Tied to ship count so the animation fires exactly when
        // the pipeline poll returns data, not a moment before.
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(.easeInOut(duration: 0.25), value: store.ships.count)
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
            Text("No active PRs")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Run \u{201C}shipyard pr\u{201D} in a worktree to see progress here.")
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
        if store.liveStartupPending { return "dot.radiowaves.left.and.right" }
        return "arrow.clockwise"
    }

    private var cadenceLabel: String {
        if case .live = store.liveStatus { return "Live via Tailscale Funnel" }
        if store.liveStartupPending { return "Starting live updates" }
        if store.liveStatus.blocksGitHubAPIPolling { return "GitHub polling paused" }
        return "Polling every 60s"
    }
}
