import SwiftUI

struct ShipCardView: View {
    let ship: Ship
    @EnvironmentObject var store: AppStore
    @State private var hovering: Bool = false
    @State private var addLaneOpen: Bool = false
    @State private var otherChecksExpanded: Bool = false
    @State private var showingArchiveConfirm: Bool = false

    /// Expansion lives in the store, not in @State, so LazyVStack
    /// recycling doesn't re-open cards the user had collapsed once
    /// they scroll off-screen and back.
    ///
    /// Default is collapsed. Actual expansion always reads from the
    /// store; the auto-expand "seed" fires from `onAppear` so the
    /// decision sticks (set once, don't flip on status changes).
    private var expanded: Bool {
        store.isExpanded(pr: ship.prNumber, defaultIfUnset: false)
    }

    private func setExpanded(_ value: Bool) {
        store.setExpanded(value, for: ship.prNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded {
                let platforms = effectivePlatformTargets()
                if !platforms.isEmpty {
                    // Primary: platform-specific lanes at the top.
                    // These are what the user actually cares about —
                    // "did my macOS / Linux / Windows / iOS runners
                    // pass?"
                    ForEach(platforms) { target in
                        TargetRowView(target: target, ship: ship)
                    }
                } else if ship.targets.isEmpty {
                    emptyTargetsRow
                }
                let otherRuns = otherWorkflowRuns()
                if !otherRuns.isEmpty {
                    collapsibleOtherChecks(otherRuns)
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
            // Proactively fetch jobs for every nested run so platform
            // lanes populate without waiting for "Other checks" to
            // be expanded.
            for run in store.githubRuns(for: ship) {
                store.fetchJobsIfNeeded(for: run)
            }
            // Auto-expand seed: one-shot decision per PR per session.
            // We set it on first onAppear when the setting is on AND
            // the PR is actively being worked on. Once set, it sticks
            // even if the PR later becomes inactive — matches the
            // "stay expanded until I collapse or quit" contract.
            if store.autoExpandActivePRs,
               !store.hasExplicitExpansion(for: ship.prNumber),
               store.isActivelyWorkedOn(ship) {
                store.setExpanded(true, for: ship.prNumber)
            }
        }
    }

    /// Workflow runs that are NOT the source of any platform lane —
    /// so the user doesn't see the same matrix jobs twice (once up
    /// top as platforms, once nested inside "Build and Test"). Also
    /// filters out workflows we've already represented at the top.
    private func otherWorkflowRuns() -> [GitHubRun] {
        let all = store.githubRuns(for: ship)
        return all.filter { run in
            let jobs = store.jobsByRunId[run.id] ?? []
            // If every job in this workflow is a platform job, it's
            // fully represented by the top section — skip it here.
            if !jobs.isEmpty, jobs.allSatisfy({ Self.platformKey($0.name) != nil }) {
                return false
            }
            return true
        }
    }

    @ViewBuilder
    private func collapsibleOtherChecks(_ runs: [GitHubRun]) -> some View {
        let tallies = countRuns(runs)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    otherChecksExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: otherChecksExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("Other checks")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text("· \(runs.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if !otherChecksExpanded {
                        Spacer()
                        // Micro-summary: counts of each status.
                        if tallies.running > 0 {
                            Circle().fill(ShipyardColors.blue).frame(width: 5, height: 5)
                            Text("\(tallies.running)")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        if tallies.failed > 0 {
                            Circle().fill(ShipyardColors.red).frame(width: 5, height: 5)
                            Text("\(tallies.failed)")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        if tallies.succeeded > 0 {
                            Circle().fill(ShipyardColors.green).frame(width: 5, height: 5)
                            Text("\(tallies.succeeded)")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    } else {
                        Spacer()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pipeline workflows that aren't tied to a specific platform — click to expand")

            if otherChecksExpanded {
                ForEach(runs) { run in
                    GitHubRunRow(run: run, compact: true, ship: ship)
                }
            }
        }
        .padding(.top, 6)
    }

    private func countRuns(_ runs: [GitHubRun]) -> (running: Int, failed: Int, succeeded: Int) {
        var r = (running: 0, failed: 0, succeeded: 0)
        for run in runs {
            if run.isRunning { r.running += 1 }
            else if run.isFailure { r.failed += 1 }
            else if run.conclusion == "success" { r.succeeded += 1 }
        }
        return r
    }

    /// Platform-level Target rows, unioned across BOTH data sources:
    ///
    ///  - Shipyard-dispatched targets (from `ship.targets`) — these
    ///    are the richest rows; they carry retarget hooks, heartbeat,
    ///    phase, and provider info.
    ///  - GitHub Actions matrix jobs grouped by OS family — these
    ///    fill in platforms shipyard didn't dispatch (e.g. shipyard
    ///    only dispatched macOS locally; Linux + Windows ran on GH
    ///    directly via the PR workflow).
    ///
    /// Before this union, the card hid non-shipyard platforms when
    /// even one shipyard target was present — so a PR with a local
    /// macOS dispatch that failed would show only `mac` and drop the
    /// green Linux / Windows GH runs from view.
    private func effectivePlatformTargets() -> [Target] {
        struct LaneData {
            var statuses: [TargetStatus] = []
            var provider: String? = nil
            var githubRunId: Int64? = nil
        }
        var shipyardByKey: [String: Target] = [:]
        var unkeyedShipyard: [Target] = []
        for t in ship.targets {
            if let key = Self.platformKey(t.name) {
                shipyardByKey[key] = t
            } else {
                unkeyedShipyard.append(t)
            }
        }
        var ghByKey: [String: LaneData] = [:]
        for run in store.githubRuns(for: ship) {
            for job in store.jobsByRunId[run.id] ?? [] {
                guard let key = Self.platformKey(job.name) else { continue }
                var d = ghByKey[key] ?? LaneData()
                d.statuses.append(Self.mapJobStatus(job))
                if job.provider != "unknown" { d.provider = job.provider }
                if d.githubRunId == nil { d.githubRunId = run.id }
                ghByKey[key] = d
            }
        }
        let order = ["macos", "linux", "windows", "ios", "android", "tvos", "watchos"]
        var result: [Target] = []
        for key in order {
            if let sy = shipyardByKey[key] {
                // Shipyard dispatch wins — it owns retarget + richer
                // metadata. GH data for the same platform is left
                // out to avoid double-counting the same matrix jobs.
                result.append(sy)
                continue
            }
            guard let d = ghByKey[key] else { continue }
            var t = Target(name: Self.canonicalPlatformName(key))
            t.status = Self.aggregateStatus(d.statuses)
            let prov = d.provider ?? "unknown"
            let provEnum = RunnerProvider(rawValue: prov == "github-hosted" ? "github" : prov)
                ?? .github
            t.runner = Runner(
                provider: provEnum,
                label: prov == "unknown" ? "gh-actions" : prov,
                detail: nil
            )
            t.githubRunId = d.githubRunId
            t.githubRepo = ship.repo
            result.append(t)
        }
        // Tack on any shipyard targets whose names don't match a
        // canonical OS family — custom / internal lanes the user
        // still cares about.
        result.append(contentsOf: unkeyedShipyard)
        return result
    }

    private static func canonicalPlatformName(_ key: String) -> String {
        switch key {
        case "macos":   return "macOS"
        case "linux":   return "Linux"
        case "windows": return "Windows"
        case "ios":     return "iOS"
        case "android": return "Android"
        case "tvos":    return "tvOS"
        case "watchos": return "watchOS"
        default:        return key.capitalized
        }
    }

    private func confirmAndArchive() {
        let alert = NSAlert()
        alert.messageText = "Archive tracking for PR #\(ship.prNumber)?"
        let warning = isActivelyRunning
            ? "\n\n⚠︎ This PR is actively running. Archiving will stop tracking it here — any running CI continues on GitHub but won't be visible in this app."
            : ""
        alert.informativeText = "Runs:\n  shipyard ship-state discard \(ship.prNumber)\n\nThe CLI keeps a tombstone; the underlying file is not deleted. You can re-list it from the terminal.\(warning)"
        alert.alertStyle = isActivelyRunning ? .critical : .warning
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.archive(ship: ship)
        }
    }

    private var isActivelyRunning: Bool {
        if ship.overallStatus == .running { return true }
        if let prState = store.prState(for: ship), !prState.isClosed {
            if !ship.targets.isEmpty && ship.overallStatus != .passed && ship.overallStatus != .failed {
                return true
            }
        }
        return false
    }

    private static func aggregateStatus(_ statuses: [TargetStatus]) -> TargetStatus {
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.running) { return .running }
        if statuses.allSatisfy({ $0 == .passed || $0 == .skipped || $0 == .reused }) {
            return .passed
        }
        return .pending
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
                    Text(verbatim: "#\(ship.prNumber)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .onTapGesture { /* absorbs the tap, preventing header toggle */ }
                .help(prLinkTooltip(for: ship))
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
                let next = !expanded
                withAnimation(.easeInOut(duration: 0.15)) { setExpanded(next) }
                if next {
                    // Re-fetch on expand — user is asking to see
                    // detail, make sure the nested section is current.
                    // Force past the TTL since this is a user-initiated
                    // refresh.
                    store.fetchRunsForShipOnDemand(ship, force: true)
                }
            }

            // Per-platform status dots (macOS, Linux, Windows, iOS,
            // Android). One dot per OS family, aggregating across
            // shipyard targets AND nested GitHub Actions matrix jobs.
            // Answers the question "did the runners I configured
            // pass?" at a glance.
            if !expanded {
                let dots = summaryDots()
                if !dots.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(dots.enumerated()), id: \.offset) { _, d in
                            Circle()
                                .fill(d.color)
                                .frame(width: 6, height: 6)
                                .help(d.tooltip)
                        }
                    }
                }
            }

            statusPill

            // Hide / archive menu. The icon is non-destructive by
            // default (just hides the card from this list). The
            // archive-to-disk option lives behind a menu item with
            // explicit confirmation — so a stray click can never
            // accidentally interrupt an active runner.
            Menu {
                Button {
                    store.dismiss(ship: ship)
                } label: {
                    Label("Hide from this list", systemImage: "eye.slash")
                }
                if ship.overallStatus == .passed
                    || ship.overallStatus == .failed
                    || (store.prState(for: ship)?.isClosed == true)
                    || ship.targets.isEmpty {
                    Divider()
                    Button(role: .destructive) {
                        confirmAndArchive()
                    } label: {
                        Label(
                            "Archive on disk (shipyard ship-state discard)",
                            systemImage: "archivebox"
                        )
                    }
                }
            } label: {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Hide this card (click). Menu includes Archive with confirmation.")
            .opacity(hovering ? 1 : 0.75)
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
            .help("Add a new target lane to this active PR")

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
            // Merged = success. Green matches how a merged PR reads
            // on GitHub and keeps "green" and "merged" visually in
            // the same family. The merge arrow icon still signals
            // "this landed" vs a plain green check.
            label = "merged"; color = ShipyardColors.green
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
                // Intentionally *not* the merge arrow — reserve that
                // icon for actually-merged PRs above. Open+green uses a
                // plain check so reviewers can tell at a glance whether
                // the PR has landed or is still awaiting merge.
                label = "green"; color = ShipyardColors.green
                icon = "checkmark.circle.fill"
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

    /// Full-fidelity text for tooltip on header fields. One tooltip
    /// covers repo + branch + worktree + PR title so hovering any of
    /// them gives the complete context.
    private func tooltip(for ship: Ship) -> String {
        var lines: [String] = []
        if let title = bestTitle(for: ship) {
            lines.append(title)
            lines.append("")  // blank separator before metadata block
        }
        if !ship.repo.isEmpty { lines.append("Repo: \(ship.repo)") }
        lines.append("PR: #\(ship.prNumber)")
        if !ship.branch.isEmpty { lines.append("Branch: \(ship.branch)") }
        if !ship.worktree.isEmpty { lines.append("Worktree: \(ship.worktree)") }
        if !ship.headSha.isEmpty { lines.append("HEAD: \(String(ship.headSha.prefix(12)))") }
        return lines.joined(separator: "\n")
    }

    /// Prefer the PR title when shipyard captured one; fall back to
    /// the commit subject (older ship-states) or nil when neither
    /// is available.
    private func bestTitle(for ship: Ship) -> String? {
        if !ship.prTitle.isEmpty { return ship.prTitle }
        if !ship.commitSubject.isEmpty { return ship.commitSubject }
        return nil
    }

    /// Tooltip for the clickable #N link: lead with the PR title when
    /// we have one so hovering a truncated header row reveals the
    /// full title (user complaint on v0.1.6 — `feature/cl…-coverage`
    /// was unreadable and the tooltip only said "Open PR #N on
    /// GitHub"). Still mentions the open-GitHub action so the click
    /// affordance is clear.
    private func prLinkTooltip(for ship: Ship) -> String {
        if let title = bestTitle(for: ship) {
            return "\(title)\n\nOpen PR #\(ship.prNumber) on GitHub"
        }
        return "Open PR #\(ship.prNumber) on GitHub"
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Per-PLATFORM status dots (not per workflow / per job). Groups
    /// every lane the app knows about — shipyard targets + nested
    /// GitHub Actions matrix jobs — by OS family and emits one dot
    /// per family colored by the worst status in that family.
    /// So pulp's "macOS (ARM64)" + "macos" + whatever else collapse
    /// to a single macOS dot instead of three.
    private func summaryDots() -> [(color: Color, tooltip: String)] {
        var statuses: [String: [TargetStatus]] = [:]
        for target in ship.targets {
            guard let key = Self.platformKey(target.name) else { continue }
            statuses[key, default: []].append(target.status)
        }
        for run in store.githubRuns(for: ship) {
            for job in store.jobsByRunId[run.id] ?? [] {
                guard let key = Self.platformKey(job.name) else { continue }
                statuses[key, default: []].append(Self.mapJobStatus(job))
            }
        }
        let order = ["macos", "linux", "windows", "ios", "android", "tvos", "watchos"]
        return order.compactMap { key in
            guard let arr = statuses[key], !arr.isEmpty else { return nil }
            let color = Self.aggregateColor(arr)
            let label = key.capitalized
            let summary = Self.summaryText(arr)
            return (color, "\(label): \(summary)")
        }
    }

    private static func platformKey(_ raw: String) -> String? {
        let l = raw.lowercased()
        if l.contains("macos") || l == "mac" || l.hasPrefix("mac ") || l.hasPrefix("mac-") { return "macos" }
        if l.contains("linux") || l.contains("ubuntu") || l.contains("debian") { return "linux" }
        if l.contains("windows") || l == "win" { return "windows" }
        if l.contains("ios") && !l.contains("macos") { return "ios" }
        if l.contains("android") { return "android" }
        if l.contains("tvos") { return "tvos" }
        if l.contains("watchos") { return "watchos" }
        return nil
    }

    private static func mapJobStatus(_ job: GitHubJob) -> TargetStatus {
        switch job.status {
        case "completed":
            if job.conclusion == "success" { return .passed }
            if job.conclusion == "skipped" { return .skipped }
            return .failed
        case "in_progress": return .running
        case "queued", "waiting", "pending": return .pending
        default: return .pending
        }
    }

    private static func aggregateColor(_ statuses: [TargetStatus]) -> Color {
        if statuses.contains(.failed) { return ShipyardColors.red }
        if statuses.contains(.running) { return ShipyardColors.blue }
        if statuses.allSatisfy({ $0 == .passed || $0 == .skipped || $0 == .reused }) {
            return ShipyardColors.green
        }
        return .secondary.opacity(0.5)
    }

    private static func summaryText(_ statuses: [TargetStatus]) -> String {
        if statuses.contains(.failed) { return "one or more lanes failing" }
        if statuses.contains(.running) { return "running" }
        if statuses.allSatisfy({ $0 == .passed || $0 == .skipped || $0 == .reused }) {
            return "all green"
        }
        return "pending"
    }
}
