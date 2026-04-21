import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var ships: [Ship] = []

    @Published var cliBinaryPath: String = UserDefaults.standard.string(forKey: Keys.cliBinaryPath) ?? "" {
        didSet {
            UserDefaults.standard.set(cliBinaryPath, forKey: Keys.cliBinaryPath)
            resolveCLIBinary()
            restartPipelineIfPossible()
        }
    }

    @Published var cliBinaryResolved: String? {
        didSet { restartPipelineIfPossible() }
    }
    @Published var cliBinaryError: String?

    @Published var lastDoctorCheckedAt: Date?
    @Published var doctorResult: DoctorResult?

    @Published var notifyOnFail: Bool = UserDefaults.standard.object(forKey: Keys.notifyOnFail) as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnFail, forKey: Keys.notifyOnFail) }
    }
    @Published var notifyOnGreen: Bool = UserDefaults.standard.object(forKey: Keys.notifyOnGreen) as? Bool ?? false {
        didSet { UserDefaults.standard.set(notifyOnGreen, forKey: Keys.notifyOnGreen) }
    }
    @Published var notifyOnMerge: Bool = UserDefaults.standard.object(forKey: Keys.notifyOnMerge) as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnMerge, forKey: Keys.notifyOnMerge) }
    }
    @Published var resumePromptOnWake: Bool = UserDefaults.standard.bool(forKey: Keys.resumePromptOnWake) {
        didSet { UserDefaults.standard.set(resumePromptOnWake, forKey: Keys.resumePromptOnWake) }
    }
    @Published var autoClearPassedMinutes: Int = UserDefaults.standard.object(forKey: Keys.autoClearPassedMinutes) as? Int ?? 60 {
        didSet { UserDefaults.standard.set(autoClearPassedMinutes, forKey: Keys.autoClearPassedMinutes) }
    }
    @Published var autoClearFailedMinutes: Int = UserDefaults.standard.object(forKey: Keys.autoClearFailedMinutes) as? Int ?? 240 {
        didSet { UserDefaults.standard.set(autoClearFailedMinutes, forKey: Keys.autoClearFailedMinutes) }
    }
    @Published var groupByWorktree: Bool = UserDefaults.standard.bool(forKey: Keys.groupByWorktree) {
        didSet { UserDefaults.standard.set(groupByWorktree, forKey: Keys.groupByWorktree) }
    }

    /// Opt-in: when true, a ship card opens by default if it has any
    /// content to show (shipyard targets OR cached GH runs on the
    /// ship's branch/SHA). Off by default — the predictable "all
    /// collapsed" layout is the baseline.
    @Published var autoExpandActivePRs: Bool = UserDefaults.standard.bool(forKey: Keys.autoExpandActivePRs) {
        didSet { UserDefaults.standard.set(autoExpandActivePRs, forKey: Keys.autoExpandActivePRs) }
    }

    /// Does this ship have anything worth expanding? Used by the
    /// auto-expand default. Uses the un-windowed run caches so a
    /// merged PR whose runs are older than the GH time window still
    /// counts as "has content" — this isn't the polling-eligibility
    /// check, it's the "does expanding reveal anything" check.
    func hasExpandableContent(for ship: Ship) -> Bool {
        if !ship.targets.isEmpty { return true }
        let branchKey = "\(ship.repo)\t\(ship.branch)"
        let repoRuns = githubRunsByRepo[ship.repo] ?? []
        let branchRuns = githubRunsByBranch[branchKey] ?? []
        for run in repoRuns + branchRuns {
            let branchMatch = !ship.branch.isEmpty && run.headBranch == ship.branch
            let shaMatch = !ship.headSha.isEmpty && run.headSha == ship.headSha
            if branchMatch || shaMatch { return true }
        }
        return false
    }

    @Published var showDemoData: Bool = UserDefaults.standard.bool(forKey: Keys.showDemoData) {
        didSet {
            UserDefaults.standard.set(showDemoData, forKey: Keys.showDemoData)
            if showDemoData {
                ships = DemoFixtures.ships
            } else {
                ships = []
                restartPipelineIfPossible()
            }
        }
    }

    @Published var hiddenStaleCount: Int = 0
    @Published var showStale: Bool = false

    // MARK: - GitHub Actions

    @Published var otherActionsExpanded: Bool = UserDefaults.standard.bool(forKey: Keys.otherActionsExpanded) {
        didSet { UserDefaults.standard.set(otherActionsExpanded, forKey: Keys.otherActionsExpanded) }
    }

    /// Bumped when the user clicks "expand all" or "collapse all" in
    /// the header. Ship cards listen and update their local expanded
    /// state.
    @Published var expandAllTick: Int = 0
    @Published var expandAllState: Bool = true

    /// Per-PR expansion state. Survives LazyVStack view recycling —
    /// without this, cards scrolled off-screen were re-initialized
    /// from their init default on scroll-back, so a "Collapse all"
    /// issued while only some cards were on-screen would silently
    /// get un-done for the off-screen cards once they came back.
    @Published var prExpansionState: [Int: Bool] = [:]

    /// Returns the stored expansion for this PR, falling back to a
    /// caller-supplied default when no explicit state has been set.
    func isExpanded(pr: Int, defaultIfUnset: Bool) -> Bool {
        prExpansionState[pr] ?? defaultIfUnset
    }

    func setExpanded(_ value: Bool, for pr: Int) {
        prExpansionState[pr] = value
    }

    func setAllExpanded(_ expanded: Bool) {
        expandAllState = expanded
        expandAllTick += 1
        // Write through for every known PR so off-screen cards stay
        // in sync with the global choice when scrolled back into view.
        for ship in ships {
            prExpansionState[ship.prNumber] = expanded
        }
    }

    // MARK: - Live updates (Tailscale Funnel webhooks)

    /// User preference: Auto (default) / On / Off. See issue #2.
    @Published var liveUpdateMode: LiveUpdateMode = LiveUpdateMode(
        rawValue: UserDefaults.standard.string(forKey: Keys.liveUpdateMode) ?? "auto"
    ) ?? .auto {
        didSet {
            UserDefaults.standard.set(liveUpdateMode.rawValue, forKey: Keys.liveUpdateMode)
            if oldValue != liveUpdateMode {
                Task { await reconcileLiveMode() }
            }
        }
    }

    /// Latest resolved runtime state (live vs polling + reason).
    @Published private(set) var liveStatus: LiveUpdateStatus = .polling(reason: .userDisabled)

    /// Latest Tailscale probe result. Re-run at launch + on foreground
    /// + every 60s while the app is open.
    @Published private(set) var tailscaleStatus: TailscaleStatus?

    private let liveController = LiveModeController()
    private var tailscaleProbeTask: Task<Void, Never>?

    /// Re-probe Tailscale and reconcile the live controller. Safe to
    /// call from anywhere — handles its own @MainActor hop.
    func reconcileLiveMode() async {
        let probe = await TailscaleProbe.probe()
        await MainActor.run {
            self.tailscaleStatus = probe
        }
        await liveController.reconcile(
            mode: liveUpdateMode,
            tailscale: probe,
            repos: Set(ships.map(\.repo)).filter { !$0.isEmpty }.union(knownRepos),
            ghBinary: resolveGHBinary()
        ) { [weak self] event in
            self?.apply(webhookEvent: event)
        }
        await MainActor.run {
            self.liveStatus = self.liveController.status
        }
    }

    /// Kick off a lightweight periodic Tailscale re-probe so
    /// Auto-mode toggles seamlessly when the user stops/starts
    /// Tailscale. Cheap: ~1 `tailscale status --json` per minute.
    func startTailscaleWatcher() {
        tailscaleProbeTask?.cancel()
        tailscaleProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await self?.reconcileLiveMode()
            }
        }
    }

    /// Translate a decoded webhook event into an AppStore mutation.
    /// The actual evictions of cached jobs/runs piggyback on the
    /// existing reconcile path so the UI stays consistent with what
    /// polling would have produced.
    private func apply(webhookEvent event: WebhookEvent) {
        switch event {
        case .workflowRun(let p):
            // Drop cached jobs for this run so the next render refreshes
            // per-platform dots from fresh data.
            jobsByRunId.removeValue(forKey: p.runId)
            // Kick a lightweight branch fetch to pull the updated run
            // back into cache. force:true bypasses the rate-limit TTL.
            if let ship = ships.first(where: { $0.repo == p.repo && $0.branch == p.headBranch }) {
                fetchRunsForShipOnDemand(ship, force: true)
            }
        case .workflowJob(let p):
            jobsByRunId.removeValue(forKey: p.runId)
            // Also re-fetch jobs for this run so the per-platform
            // rollup reflects the new status immediately.
            if let existing = githubRunsByRepo[p.repo]?.first(where: { $0.id == p.runId }) {
                fetchJobsIfNeeded(for: existing)
            }
        case .pullRequest(let p):
            // Drop cached PR state so the next render re-fetches.
            let key = prKey(repo: p.repo, pr: p.number)
            prStateByKey.removeValue(forKey: key)
            if let ship = ships.first(where: { $0.repo == p.repo && $0.prNumber == p.number }) {
                fetchPRStateIfNeeded(for: ship)
            }
        case .unhandled:
            break
        }
    }

    @Published var showGitHubActions: Bool = UserDefaults.standard.object(forKey: Keys.showGitHubActions) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showGitHubActions, forKey: Keys.showGitHubActions)
            if showGitHubActions {
                startGitHubPolling()
            } else {
                stopGitHubPolling()
                githubRunsByRepo = [:]
            }
        }
    }

    @Published var ghWindowMinutes: Int = UserDefaults.standard.object(forKey: Keys.ghWindowMinutes) as? Int ?? 240 {
        didSet { UserDefaults.standard.set(ghWindowMinutes, forKey: Keys.ghWindowMinutes) }
    }

    @Published var ghWorkflowBlocklist: String = UserDefaults.standard.string(forKey: Keys.ghWorkflowBlocklist) ?? "" {
        didSet { UserDefaults.standard.set(ghWorkflowBlocklist, forKey: Keys.ghWorkflowBlocklist) }
    }

    @Published var githubRunsByRepo: [String: [GitHubRun]] = [:]
    /// Per-branch cache keyed by "repo\tbranch". Populated on card-
    /// expand so even old PR branches surface real runs.
    @Published var githubRunsByBranch: [String: [GitHubRun]] = [:]

    private var githubPollTask: Task<Void, Never>?

    private var pipeline: ShipyardPipeline?
    private var lastBadge: OverallBadge = .idle

    var overallBadge: OverallBadge {
        ships.filter { !$0.dismissed }.overallBadge
    }

    /// Union of every target name that's ever shown up across ships in
    /// this session. Used as the picker source for "Add lane" so the
    /// user doesn't have to type common targets.
    var knownTargetNames: [String] {
        let names = Set(ships.flatMap { $0.targets.map(\.name) })
        return names.sorted()
    }

    /// Candidate target names for a specific ship's Add Lane picker.
    /// Returns canonical OS names (macOS, Linux, Windows, etc.) —
    /// one entry per unique platform the user could dispatch to.
    /// Matches the prototype's short, curated list instead of
    /// flooding with every matrix-job name.
    func candidateTargetNames(for ship: Ship) -> [String] {
        var platformsSeen: Set<String> = []
        for name in knownTargetNames {
            if let key = Self.canonicalKey(for: name) { platformsSeen.insert(key) }
        }
        for run in githubRuns(for: ship) {
            for job in jobsByRunId[run.id] ?? [] {
                if let key = Self.canonicalKey(for: job.name) { platformsSeen.insert(key) }
            }
        }
        let canonicalOrder = ["macos", "linux", "windows", "ios", "android", "tvos", "watchos"]
        return canonicalOrder
            .filter { platformsSeen.contains($0) }
            .map(Self.canonicalDisplayName)
    }

    private static func canonicalKey(for raw: String) -> String? {
        let l = raw.lowercased()
        if l.contains("macos") || l == "mac" { return "macos" }
        if l.contains("linux") || l.contains("ubuntu") || l.contains("debian") { return "linux" }
        if l.contains("windows") || l == "win" { return "windows" }
        if l.contains("ios") && !l.contains("macos") { return "ios" }
        if l.contains("android") { return "android" }
        if l.contains("tvos") { return "tvos" }
        if l.contains("watchos") { return "watchos" }
        return nil
    }

    private static func canonicalDisplayName(_ key: String) -> String {
        switch key {
        case "macos":   return "macOS"
        case "linux":   return "Linux"
        case "windows": return "Windows"
        case "ios":     return "iOS"
        case "android": return "Android"
        case "tvos":    return "tvOS"
        case "watchos": return "watchOS"
        default: return key.capitalized
        }
    }

    /// Canonical platform names currently represented on a ship —
    /// either as a shipyard dispatched target OR as a GitHub Actions
    /// matrix job. Used by Add Lane to filter "New targets" to
    /// platforms NOT already running, and populate the "Parallel on
    /// existing" section with platforms that ARE running.
    func currentPlatformNames(for ship: Ship) -> [String] {
        var keys: Set<String> = []
        for t in ship.targets {
            if let k = Self.canonicalKey(for: t.name) { keys.insert(k) }
        }
        for run in githubRuns(for: ship) {
            for job in jobsByRunId[run.id] ?? [] {
                if let k = Self.canonicalKey(for: job.name) { keys.insert(k) }
            }
        }
        let order = ["macos", "linux", "windows", "ios", "android", "tvos", "watchos"]
        return order.filter(keys.contains).map(Self.canonicalDisplayName)
    }

    /// Dedupe bare platform names (e.g. "linux") when a more
    /// specific candidate exists (e.g. "Linux (x64)"). Keeps the
    /// specific one; drops the bare one. Prevents the picker from
    /// showing three nearly-identical rows.
    private static func dedupePlatformNames(_ input: [String]) -> [String] {
        let bareTokens: Set<String> = ["linux", "windows", "macos", "mac", "ubuntu", "ios", "android", "win"]
        var result: [String] = []
        for name in input {
            let lower = name.lowercased()
            // If this is a bare platform word, check if a more
            // specific variant exists in the input.
            if bareTokens.contains(lower) {
                let hasMoreSpecific = input.contains { other in
                    guard other != name else { return false }
                    let otherLower = other.lowercased()
                    return otherLower.hasPrefix(lower + " ")
                        || otherLower.hasPrefix(lower + "(")
                        || otherLower.hasPrefix(lower + "-")
                        || otherLower.hasPrefix(lower + "_")
                }
                if hasMoreSpecific { continue }
            }
            result.append(name)
        }
        return result
    }

    /// Heuristic for "is this a platform/target name worth offering
    /// as an Add-Lane option?" — if it mentions an OS or CPU arch we
    /// recognize, yes. Otherwise it's likely a pipeline sub-job and
    /// shouldn't be offered.
    private static func looksLikePlatformTarget(_ name: String) -> Bool {
        let lower = name.lowercased()
        let platforms = [
            "macos", "mac", "linux", "windows", "win",
            "ubuntu", "ios", "android", "tvos", "watchos",
        ]
        let archs = [
            "x86_64", "x86-64", "x64", "x86",
            "arm64", "aarch64", "amd64",
            "universal",
        ]
        if platforms.contains(where: { lower.contains($0) }) { return true }
        if archs.contains(where: { lower.contains($0) }) { return true }
        return false
    }

    init() {
        resolveCLIBinary()
        if showDemoData {
            ships = DemoFixtures.ships
        } else {
            restartPipelineIfPossible()
        }
        if cliBinaryResolved != nil {
            Task { await runDoctor() }
        }
        if showGitHubActions {
            startGitHubPolling()
        }
        liveController.onStatusChange = { [weak self] newStatus in
            Task { @MainActor in self?.liveStatus = newStatus }
        }
        liveController.restorePersistedRegistrations()
        Task { [weak self] in
            await self?.reconcileLiveMode()
            await MainActor.run { self?.startTailscaleWatcher() }
        }
    }

    func dismiss(ship: Ship) {
        guard let index = ships.firstIndex(where: { $0.id == ship.id }) else { return }
        ships[index].dismissed = true
    }

    /// Undo of a local hide — clears the dismissed flag on every
    /// currently-hidden ship so they reappear in the list. The
    /// CLI ship-state isn't touched (hide was local-only), so this
    /// is a pure UI restore.
    func restoreAllHidden() {
        for i in ships.indices where ships[i].dismissed {
            ships[i].dismissed = false
        }
    }

    var hiddenCount: Int {
        ships.filter(\.dismissed).count
    }

    /// Archive the underlying ship-state file via the CLI. Use this when
    /// the user wants a stale entry truly gone, not just hidden locally.
    /// Idempotent — CLI returns success even if the state was already
    /// archived.
    func archive(ship: Ship) {
        guard let binary = cliBinaryResolved else {
            dismiss(ship: ship)
            return
        }
        let pr = ship.prNumber
        Task.detached {
            _ = await runShipyardCapturingStdout(
                binary: binary,
                args: ["ship-state", "discard", "\(pr)"]
            )
        }
        dismiss(ship: ship)
    }

    /// Sweeps terminal / closed ships out of the local view. Never
    /// touches dismissed (hidden) ships — those live behind the
    /// "Show N hidden" undo button and user chose to set them aside.
    func clearCompleted() {
        ships.removeAll { ship in
            guard !ship.dismissed else { return false }
            return isCompleted(ship)
        }
        for ship in ships where !ship.dismissed {
            fetchPRStateIfNeeded(for: ship)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                self?.ships.removeAll { ship in
                    guard !ship.dismissed else { return false }
                    return self?.isCompleted(ship) == true
                }
            }
        }
    }

    private func isCompleted(_ ship: Ship) -> Bool {
        if ship.overallStatus == .passed || ship.overallStatus == .failed {
            return true
        }
        if let pr = prState(for: ship), pr.isClosed {
            return true
        }
        return false
    }

    func toggleAutoMerge(for ship: Ship) {
        guard let index = ships.firstIndex(where: { $0.id == ship.id }) else { return }
        ships[index].autoMerge.toggle()
        if ships[index].autoMerge, let binary = cliBinaryResolved {
            let pr = ship.prNumber
            Task.detached {
                _ = await runShipyardCapturingStdout(
                    binary: binary,
                    args: ["auto-merge", "\(pr)"]
                )
            }
        }
    }

    /// Retarget one target on an in-flight ship to a new provider.
    func retarget(ship: Ship, target: Target, toProvider provider: RunnerProvider) async -> String {
        guard let binary = cliBinaryResolved else { return "CLI not available." }
        return await runShipyardCapturingStdout(
            binary: binary,
            args: [
                "cloud", "retarget",
                "--pr", "\(ship.prNumber)",
                "--target", target.name,
                "--provider", provider.rawValue,
                "--apply",
            ]
        )
    }

    func resolveCLIBinary() {
        if !cliBinaryPath.isEmpty, FileManager.default.isExecutableFile(atPath: cliBinaryPath) {
            cliBinaryResolved = cliBinaryPath
            cliBinaryError = nil
            return
        }
        let candidates = [
            "/usr/local/bin/shipyard",
            "/opt/homebrew/bin/shipyard",
            NSHomeDirectory() + "/.pulp/bin/shipyard",
            NSHomeDirectory() + "/.local/bin/shipyard",
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cliBinaryResolved = candidate
                cliBinaryError = nil
                return
            }
        }
        cliBinaryResolved = nil
        cliBinaryError = "shipyard binary not found. Set path in Settings or install the CLI first."
    }

    func restartPipelineIfPossible() {
        let oldPipeline = pipeline
        pipeline = nil
        if let old = oldPipeline {
            Task { await old.stop() }
        }
        guard let binary = cliBinaryResolved else { return }
        let newPipeline = ShipyardPipeline(binary: binary)
        pipeline = newPipeline
        Task {
            await newPipeline.start { [weak self] entries in
                Task { @MainActor in
                    self?.applySnapshot(entries)
                }
            }
        }
    }

    private func applySnapshot(_ entries: [ShipStateListEntry]) {
        let byPR: [Int: Ship] = Dictionary(
            uniqueKeysWithValues: ships.map { ($0.prNumber, $0) }
        )
        var updated: [Ship] = []
        var seenPRs: Set<Int> = []
        for entry in entries {
            var ship = Ship(from: entry)
            if let existing = byPR[entry.pr] {
                ship.dismissed = existing.dismissed
                ship.autoMerge = existing.autoMerge
            }
            updated.append(ship)
            seenPRs.insert(entry.pr)
        }

        // Preserve hidden ships that fell off the CLI's ship-state
        // list (e.g. because shipyard auto-archived them, or the user
        // ran `ship-state discard` elsewhere). Otherwise a hidden
        // ship disappearing from the snapshot evaporates from the
        // store, and "Show N hidden" can't bring it back. Dismissed
        // ships persist until the user explicitly restores or quits.
        for old in ships where old.dismissed && !seenPRs.contains(old.prNumber) {
            updated.append(old)
        }

        for ship in updated {
            fetchPRStateIfNeeded(for: ship)
            // Skip auto-refresh for ships that can't transition again
            // (merged / closed / stable terminal status). The user can
            // still force a fetch by expanding the card. Active ships
            // go through the TTL inside fetchRunsForShipOnDemand, so a
            // high-cadence NDJSON stream doesn't burn the REST budget.
            if ship.dismissed { continue }
            if let pr = prState(for: ship), pr.isClosed { continue }
            fetchRunsForShipOnDemand(ship)
        }

        // Auto-clear stale terminal ships. `shipyard ship-state list`
        // returns every state that wasn't explicitly archived, which
        // includes ships from weeks ago. Showing those poisons the
        // overall badge (any old fail → "failed"). Honor the
        // Settings → Auto-clear intervals.
        //
        // "Terminal" includes: overallStatus == .passed / .failed OR
        // PR state is merged / closed. Ships with empty targets (and
        // therefore .pending status) would otherwise never age out
        // even when their PR merged long ago — the merged signal from
        // PR state catches them.
        let now = Date()
        var hidden = 0
        let filtered = updated.filter { ship in
            let status = ship.overallStatus
            let pr = prState(for: ship)
            let isTerminalByStatus = status == .passed || status == .failed
            let isTerminalByPR = pr?.isClosed == true
            guard isTerminalByStatus || isTerminalByPR else { return true }
            // Merged/closed follows the "passed" TTL; genuine
            // shipyard failures follow the failed TTL.
            let limit = (status == .failed && pr?.isMerged != true)
                ? autoClearFailedMinutes
                : autoClearPassedMinutes
            if limit <= 0 { return true } // 0 / Never
            let ageMinutes = now.timeIntervalSince(ship.startedAt) / 60.0
            if ageMinutes < Double(limit) { return true }
            hidden += 1
            return false
        }

        hiddenStaleCount = hidden
        // Sort by activity priority so the most actionable items
        // bubble to the top: running → failed → queued → green →
        // merged/closed. Within a bucket, most recently updated first.
        ships = (showStale ? updated : filtered)
            .sorted { a, b in
                let ap = activityRank(for: a)
                let bp = activityRank(for: b)
                if ap != bp { return ap < bp }
                return a.startedAt > b.startedAt
            }
        let previousRepos = knownRepos
        knownRepos.formUnion(updated.map(\.repo).filter { !$0.isEmpty })
        // If the snapshot surfaced new repos after live mode
        // reconciled at launch (empty-repo race), re-run reconcile
        // so webhooks get registered on them.
        if knownRepos != previousRepos {
            Task { [weak self] in await self?.reconcileLiveMode() }
        }
        detectBadgeTransition()
    }

    /// Lower rank = higher in the list. Uses PR state when we have it
    /// so merged PRs always sink; otherwise ranks by overall status.
    private func activityRank(for ship: Ship) -> Int {
        if let prState = prState(for: ship), prState.isMerged { return 90 }
        if let prState = prState(for: ship), prState.isClosed { return 95 }
        switch ship.overallStatus {
        case .running: return 10
        case .failed:  return 20
        case .pending: return 40 // queued / awaiting CI
        case .reused:  return 50
        case .skipped: return 60
        case .passed:  return 70
        }
    }

    private func detectBadgeTransition() {
        let newBadge = overallBadge
        if newBadge != lastBadge {
            Notifier.maybeNotify(
                from: lastBadge,
                to: newBadge,
                prefs: (fail: notifyOnFail, green: notifyOnGreen, merge: notifyOnMerge)
            )
            lastBadge = newBadge
        }
    }

    // MARK: - GitHub Actions

    /// Repos we've ever seen in ship-state — the set we'll poll for
    /// Actions runs. Grows as the user ships new repos; never shrinks
    /// within a session.
    private var knownRepos: Set<String> = []

    func startGitHubPolling() {
        stopGitHubPolling()
        githubPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollGitHubOnce()
                let interval = await MainActor.run {
                    self?.pollIntervalNanoseconds ?? 60_000_000_000
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Poll cadence: 60s when live mode isn't active (today's
    /// behavior), 300s when live mode is active (webhooks do the
    /// heavy lifting; poll is just a reconciler for missed events).
    @MainActor
    var pollIntervalNanoseconds: UInt64 {
        if case .live = liveStatus { return 300_000_000_000 }
        return 60_000_000_000
    }

    func stopGitHubPolling() {
        githubPollTask?.cancel()
        githubPollTask = nil
    }

    private func pollGitHubOnce() async {
        let repos = await MainActor.run { self.knownRepos }
        for repo in repos {
            if let runs = await GitHubActionsPoller.fetch(repo: repo, limit: 100) {
                await MainActor.run {
                    let previous = self.githubRunsByRepo[repo] ?? []
                    self.githubRunsByRepo[repo] = runs
                    self.reconcileJobsCache(newRuns: runs, oldRuns: previous)
                    for run in runs {
                        self.fetchJobsIfNeeded(for: run)
                    }
                }
            }
        }
    }

    /// Drops cached job data for any run whose status or conclusion
    /// changed between polls. Without this, a run that transitioned
    /// from in_progress (red/yellow jobs) to completed (green jobs)
    /// would keep serving the old job rollup until the user manually
    /// re-triggered a fetch by expanding the card.
    private func reconcileJobsCache(newRuns: [GitHubRun], oldRuns: [GitHubRun]) {
        let oldByID = Dictionary(uniqueKeysWithValues: oldRuns.map { ($0.id, $0) })
        for run in newRuns {
            guard let prev = oldByID[run.id] else { continue }
            if prev.status != run.status || prev.conclusion != run.conclusion {
                jobsByRunId.removeValue(forKey: run.id)
            }
        }
    }

    // Helper used by ghAction — must be at actor scope.
    fileprivate func runGHSync(executable: String, args: [String]) async -> String {
        await runGHCapturing(executable: executable, args: args)
    }

    /// Filter + window-cutoff + blocklist + ensure this run is within
    /// the "we'd consider showing this" set. Used by both the rollup
    /// (runs inside a ship card) and the unrelated-runs section.
    private func eligibleRun(_ run: GitHubRun, blocked: [String], cutoff: Date) -> Bool {
        guard run.createdAt >= cutoff else { return false }
        let name = run.workflowName.lowercased()
        if blocked.contains(where: { name.contains($0) }) { return false }
        return true
    }

    private func currentBlocklist() -> [String] {
        ghWorkflowBlocklist
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func currentCutoff() -> Date {
        Date().addingTimeInterval(-Double(ghWindowMinutes) * 60)
    }

    /// GitHub Actions runs that are explicitly tied to a specific
    /// ship. Union of two data sources: repo-wide cache (fast,
    /// covers newest runs) and branch-scoped cache (populated on
    /// expand, catches older branches outside the repo-wide slice).
    /// Match by head_sha (exact) OR head_branch.
    func githubRuns(for ship: Ship) -> [GitHubRun] {
        guard showGitHubActions else { return [] }
        let blocked = currentBlocklist()
        let cutoff = currentCutoff()
        var seen: Set<Int64> = []
        var result: [GitHubRun] = []
        let sources: [[GitHubRun]] = [
            githubRunsByRepo[ship.repo] ?? [],
            githubRunsByBranch["\(ship.repo)\t\(ship.branch)"] ?? [],
        ]
        for source in sources {
            for run in source where eligibleRun(run, blocked: blocked, cutoff: cutoff) {
                let branchMatch = !ship.branch.isEmpty && run.headBranch == ship.branch
                let shaMatch = !ship.headSha.isEmpty && run.headSha == ship.headSha
                guard branchMatch || shaMatch else { continue }
                if seen.insert(run.id).inserted {
                    result.append(run)
                }
            }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// Inflight guard for branch-scoped run fetches. Applies to both
    /// user-triggered expands and the periodic refresh from
    /// applySnapshot — prevents duplicate `gh run list` calls piling
    /// up when a ship's snapshot lands faster than the network.
    private var inflightBranchFetches: Set<String> = []

    /// Last wall-clock fetch time per branch. Paired with
    /// `branchFetchTTL` to rate-limit automatic priming from
    /// applySnapshot so a high-cadence NDJSON stream doesn't burn
    /// the GitHub REST core budget (5,000/hr).
    private var lastBranchFetch: [String: Date] = [:]
    private let branchFetchTTL: TimeInterval = 60

    /// Fires `gh run list --branch <ship.branch>` to backfill runs
    /// outside the repo-wide top-100 window and to pick up status
    /// transitions the repo-wide poll missed. Background callers
    /// (applySnapshot) must not pass `force`; user-initiated callers
    /// (card expand) pass `force: true` so the user always gets a
    /// fresh fetch when they explicitly ask for detail.
    func fetchRunsForShipOnDemand(_ ship: Ship, force: Bool = false) {
        guard showGitHubActions,
              !ship.repo.isEmpty,
              !ship.branch.isEmpty else { return }
        let repo = ship.repo
        let branch = ship.branch
        let key = "\(repo)\t\(branch)"
        if inflightBranchFetches.contains(key) { return }
        if !force,
           let last = lastBranchFetch[key],
           Date().timeIntervalSince(last) < branchFetchTTL {
            return
        }
        inflightBranchFetches.insert(key)
        Task {
            let runs = await GitHubActionsPoller.fetch(
                repo: repo, branch: branch, limit: 50
            )
            await MainActor.run {
                defer { self.inflightBranchFetches.remove(key) }
                self.lastBranchFetch[key] = Date()
                guard let runs else { return }
                let previous = self.githubRunsByBranch[key] ?? []
                self.githubRunsByBranch[key] = runs
                self.reconcileJobsCache(newRuns: runs, oldRuns: previous)
                for run in runs {
                    self.fetchJobsIfNeeded(for: run)
                }
            }
        }
    }

    // MARK: - PR state on github.com

    /// Cache of PR state from github.com. Keyed by "repo\tpr".
    /// Absent = not fetched; present = fetched.
    @Published var prStateByKey: [String: PRState] = [:]
    private var inflightPRStateFetches: Set<String> = []

    private func prKey(repo: String, pr: Int) -> String { "\(repo)\t\(pr)" }

    func prState(for ship: Ship) -> PRState? {
        prStateByKey[prKey(repo: ship.repo, pr: ship.prNumber)]
    }

    func fetchPRStateIfNeeded(for ship: Ship) {
        let key = prKey(repo: ship.repo, pr: ship.prNumber)
        if prStateByKey[key] != nil { return }
        if inflightPRStateFetches.contains(key) { return }
        inflightPRStateFetches.insert(key)
        let repo = ship.repo
        let pr = ship.prNumber
        Task {
            if let state = await PRStatePoller.fetch(repo: repo, pr: pr) {
                await MainActor.run {
                    self.prStateByKey[key] = state
                    self.inflightPRStateFetches.remove(key)
                }
            } else {
                await MainActor.run {
                    self.inflightPRStateFetches.remove(key)
                }
            }
        }
    }

    // MARK: - Per-run job details (runner provider)

    /// Keyed by run id. Populated by fetchJobsIfNeeded and read by
    /// views. Absence means "not fetched yet"; empty array means
    /// "fetched, but no jobs."
    @Published var jobsByRunId: [Int64: [GitHubJob]] = [:]
    private var inflightJobFetches: Set<Int64> = []

    func fetchJobsIfNeeded(for run: GitHubRun) {
        guard showGitHubActions else { return }
        if jobsByRunId[run.id] != nil { return }
        if inflightJobFetches.contains(run.id) { return }
        inflightJobFetches.insert(run.id)
        let repo = run.repo
        let id = run.id
        Task {
            let jobs = await GitHubActionsPoller.fetchJobs(repo: repo, runId: id) ?? []
            await MainActor.run {
                self.jobsByRunId[id] = jobs
                self.inflightJobFetches.remove(id)
            }
        }
    }

    /// Best-effort runner-provider summary for a run: the distinct set
    /// of providers across its jobs. Returns nil if we haven't fetched
    /// yet; empty array if the run has no jobs (rare).
    func providers(for run: GitHubRun) -> [String]? {
        guard let jobs = jobsByRunId[run.id] else { return nil }
        let uniq = Array(Set(jobs.map(\.provider))).sorted()
        return uniq
    }

    /// When a ship has no dispatched_runs of its own but GitHub did
    /// run CI via push triggers, compute the ship's effective status
    /// from the nested GitHub runs. This turns a misleading "not
    /// dispatched" pill into an accurate "running" / "green" /
    /// "failed" pill. Returns nil if there are no nested runs yet.
    func derivedStatusFromGitHub(for ship: Ship) -> TargetStatus? {
        let runs = githubRuns(for: ship)
        guard !runs.isEmpty else { return nil }
        if runs.contains(where: { $0.isFailure }) { return .failed }
        if runs.contains(where: { $0.isRunning }) { return .running }
        if runs.allSatisfy({ $0.conclusion == "success" || $0.conclusion == "skipped" }) {
            return .passed
        }
        return .pending
    }

    /// GitHub Actions runs that do NOT belong to any ship card. These
    /// are tag-triggered workflows (auto-release, release), scheduled
    /// workflows (post-tag-sync), direct pushes to main, or runs for
    /// PRs we don't have local ship-state for. Shown in the "GitHub
    /// Actions" section below the ship cards.
    func unrelatedGitHubRuns() -> [String: [GitHubRun]] {
        let blocked = currentBlocklist()
        let cutoff = currentCutoff()
        // Set of (repo, branch) and (repo, sha) tuples already owned
        // by a ship card. If a run matches either, it's owned and
        // doesn't belong here.
        var ownedBranches: Set<String> = []
        var ownedShas: Set<String> = []
        for ship in ships where !ship.dismissed {
            if !ship.branch.isEmpty {
                ownedBranches.insert("\(ship.repo)\t\(ship.branch)")
            }
            if !ship.headSha.isEmpty {
                ownedShas.insert("\(ship.repo)\t\(ship.headSha)")
            }
        }
        var result: [String: [GitHubRun]] = [:]
        for (repo, runs) in githubRunsByRepo {
            let filtered = runs.filter { run in
                guard eligibleRun(run, blocked: blocked, cutoff: cutoff) else { return false }
                let branchKey = "\(run.repo)\t\(run.headBranch)"
                let shaKey = "\(run.repo)\t\(run.headSha)"
                if ownedBranches.contains(branchKey) { return false }
                if ownedShas.contains(shaKey) { return false }
                return true
            }
            if !filtered.isEmpty {
                result[repo] = filtered.sorted { $0.createdAt > $1.createdAt }
            }
        }
        return result
    }

    /// Back-compat alias; older callers referenced this name.
    func visibleGitHubRuns() -> [String: [GitHubRun]] {
        unrelatedGitHubRuns()
    }

    // MARK: - Doctor

    func runDoctor() async {
        guard let binary = cliBinaryResolved else { return }
        let raw = await runShipyardCapturingStdout(binary: binary, args: ["--json", "doctor"])
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            doctorResult = DoctorResult(ok: false, sections: [], rawJSON: raw)
            lastDoctorCheckedAt = Date()
            return
        }
        var sections: [DoctorSection] = []
        if let checks = json["checks"] as? [String: [String: Any]] {
            for (sectionName, items) in checks.sorted(by: { $0.key < $1.key }) {
                var entries: [DoctorEntry] = []
                for (name, payload) in items.sorted(by: { $0.key < $1.key }) {
                    guard let dict = payload as? [String: Any] else { continue }
                    entries.append(DoctorEntry(
                        name: name,
                        ok: dict["ok"] as? Bool ?? false,
                        version: dict["version"] as? String,
                        detail: dict["detail"] as? String
                    ))
                }
                sections.append(DoctorSection(name: sectionName, entries: entries))
            }
        }
        let ok = (json["ready"] as? Bool) ?? sections.allSatisfy { $0.entries.allSatisfy(\.ok) }
        doctorResult = DoctorResult(ok: ok, sections: sections, rawJSON: raw)
        lastDoctorCheckedAt = Date()
    }

    private enum Keys {
        static let cliBinaryPath = "cliBinaryPath"
        static let notifyOnFail = "notifyOnFail"
        static let notifyOnGreen = "notifyOnGreen"
        static let notifyOnMerge = "notifyOnMerge"
        static let resumePromptOnWake = "resumePromptOnWake"
        static let autoClearPassedMinutes = "autoClearPassedMinutes"
        static let autoClearFailedMinutes = "autoClearFailedMinutes"
        static let groupByWorktree = "groupByWorktree"
        static let showDemoData = "showDemoData"
        static let showGitHubActions = "showGitHubActions"
        static let ghWindowMinutes = "ghWindowMinutes"
        static let ghWorkflowBlocklist = "ghWorkflowBlocklist"
        static let otherActionsExpanded = "otherActionsExpanded"
        static let liveUpdateMode = "liveUpdateMode"
        static let autoExpandActivePRs = "autoExpandActivePRs"
    }

    /// Cancel or rerun a GitHub Actions run via `gh run …`. Both are
    /// fire-and-forget; the next poll will reflect the new state.
    func cancelGitHubRun(_ run: GitHubRun) {
        ghAction(run: run, verb: "cancel")
    }
    func rerunGitHubRun(_ run: GitHubRun) {
        ghAction(run: run, verb: "rerun")
    }
    private func ghAction(run: GitHubRun, verb: String) {
        guard let gh = resolveGHBinary() else { return }
        Task.detached {
            _ = await runGHCapturing(executable: gh, args: [
                "run", verb, "\(run.id)", "--repo", run.repo,
            ])
        }
    }
    private func resolveGHBinary() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct DoctorEntry: Identifiable, Equatable {
    let name: String
    let ok: Bool
    let version: String?
    let detail: String?
    var id: String { name }
}

struct DoctorSection: Identifiable, Equatable {
    let name: String
    let entries: [DoctorEntry]
    var id: String { name }
}

struct DoctorResult: Equatable {
    let ok: Bool
    let sections: [DoctorSection]
    let rawJSON: String
}
