import Foundation
import Combine
import ServiceManagement

@MainActor
final class AppStore: ObservableObject {
    @Published var ships: [Ship] = []
    /// False until the first pipeline snapshot arrives. Used by the
    /// empty-state view to distinguish "we haven't loaded yet" (show
    /// spinner) from "truly no active PRs" (show anchor + copy).
    @Published var hasLoadedInitialShips: Bool = false

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
        didSet {
            UserDefaults.standard.set(autoClearPassedMinutes, forKey: Keys.autoClearPassedMinutes)
            reapplyAutoClearFilter()
        }
    }
    @Published var autoClearFailedMinutes: Int = UserDefaults.standard.object(forKey: Keys.autoClearFailedMinutes) as? Int ?? 240 {
        didSet {
            UserDefaults.standard.set(autoClearFailedMinutes, forKey: Keys.autoClearFailedMinutes)
            reapplyAutoClearFilter()
        }
    }

    /// The most recent `updated` list from applySnapshot, kept unfiltered
    /// so auto-clear setting changes can be re-applied instantly without
    /// waiting for the next 7s poll (which also incurs the ~5-6s CLI
    /// cold-start). Populated inside applySnapshot; read by
    /// `reapplyAutoClearFilter`.
    private var lastRawSnapshot: [Ship] = []
    @Published var groupByWorktree: Bool = UserDefaults.standard.bool(forKey: Keys.groupByWorktree) {
        didSet { UserDefaults.standard.set(groupByWorktree, forKey: Keys.groupByWorktree) }
    }

    /// When true, Shipyard.app relaunches automatically at login
    /// (survives reboots). Backed by `SMAppService.mainApp` — the
    /// macOS 13+ replacement for the retired LSSharedFileList API.
    /// Default off: menu-bar apps that auto-launch without the user's
    /// explicit opt-in feel like spyware. The didSet pushes the state
    /// into the system login-items registry; `syncLaunchAtLoginFromSystem`
    /// runs at startup to absorb any change the user made in System
    /// Settings → General → Login Items without us knowing.
    @Published var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: Keys.launchAtLogin) {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLoginRegistration()
        }
    }

    /// Opt-in: when true, any PR that's actively being worked on
    /// (see `isActivelyWorkedOn`) expands automatically. Session-
    /// sticky — once expanded, stays expanded unless the user
    /// collapses or the app quits.
    @Published var autoExpandActivePRs: Bool = UserDefaults.standard.bool(forKey: Keys.autoExpandActivePRs) {
        didSet {
            UserDefaults.standard.set(autoExpandActivePRs, forKey: Keys.autoExpandActivePRs)
            if autoExpandActivePRs {
                reseedAutoExpand()
            }
        }
    }

    /// For every ship that doesn't have an explicit expanded/collapsed
    /// choice yet, seed to expanded if it qualifies as "actively
    /// worked on." Safe to call repeatedly — idempotent once a PR has
    /// an explicit value (either user-set or previously seeded).
    /// Called after any data arrival that could flip `isActivelyWorkedOn`:
    /// ship snapshots, repo-wide GH polls, branch-scoped fetches, job
    /// fetches. Without this, the first ShipCardView.onAppear fires
    /// before GH data lands and the seed never catches active PRs.
    func reseedAutoExpand() {
        guard autoExpandActivePRs else { return }
        for ship in ships {
            if prExpansionState[ship.prNumber] == nil,
               isActivelyWorkedOn(ship) {
                prExpansionState[ship.prNumber] = true
            }
        }
    }

    /// Is this PR actively being worked on right now? Drives the
    /// auto-expand default when the setting is on.
    ///
    /// "Active" means all of:
    ///  - PR state has been fetched from github.com (so we actually
    ///    know whether it's open or closed), AND
    ///  - PR is open, AND
    ///  - has shipyard targets, OR has a currently-running GitHub
    ///    Actions run, OR has any GH run updated within 30 min.
    ///
    /// The "PR state fetched" gate keeps us from seeding merged PRs
    /// as active during the brief window between ship list load and
    /// PR-state fetch. Once state arrives, `reseedAutoExpand` runs
    /// again and picks up any genuinely active PR.
    func isActivelyWorkedOn(_ ship: Ship) -> Bool {
        guard let pr = prState(for: ship) else { return false }
        if pr.isClosed { return false }
        if !ship.targets.isEmpty { return true }
        let cutoff = Date().addingTimeInterval(-30 * 60)
        let branchKey = "\(ship.repo)\t\(ship.branch)"
        let all = (githubRunsByRepo[ship.repo] ?? [])
            + (githubRunsByBranch[branchKey] ?? [])
        for run in all {
            let branchMatch = !ship.branch.isEmpty && run.headBranch == ship.branch
            let shaMatch = !ship.headSha.isEmpty && run.headSha == ship.headSha
            guard branchMatch || shaMatch else { continue }
            if run.isRunning { return true }
            if run.updatedAt >= cutoff { return true }
        }
        return false
    }

    // Demo-data toggle is a developer convenience. In Release builds
    // (no DEBUG flag) the stored pref is ignored and the toggle is
    // hidden from Settings — shipped DMGs never show fixture data
    // even if an older Debug run flipped the pref.
    @Published var showDemoData: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.showDemoData)
        #else
        return false
        #endif
    }() {
        didSet {
            #if DEBUG
            UserDefaults.standard.set(showDemoData, forKey: Keys.showDemoData)
            if showDemoData {
                ships = DemoFixtures.ships
            } else {
                ships = []
                restartPipelineIfPossible()
            }
            #endif
        }
    }

    @Published var hiddenStaleCount: Int = 0
    @Published var showStale: Bool = false {
        didSet { reapplyAutoClearFilter() }
    }

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

    /// True when a PR has been explicitly expanded or collapsed —
    /// either by the user or by the auto-expand seed. Lets the seed
    /// code avoid re-seeding once a card already has a choice.
    func hasExplicitExpansion(for pr: Int) -> Bool {
        prExpansionState[pr] != nil
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
                if liveUpdateMode == .off {
                    deferredLiveStartupTask?.cancel()
                    deferredLiveStartupTask = nil
                    liveStartupPending = false
                    Task { await reconcileLiveMode() }
                } else {
                    scheduleDeferredLiveStartup(after: 0)
                }
            }
        }
    }

    /// Latest resolved runtime state (live vs polling + reason).
    @Published private(set) var liveStatus: LiveUpdateStatus = .polling(reason: nil)
    @Published private(set) var liveStartupPending: Bool = false

    /// Latest Tailscale probe result. Re-run at launch + on foreground
    /// + every 60s while the app is open.
    @Published private(set) var tailscaleStatus: TailscaleStatus?

    private let liveController = DaemonClient()
    private var tailscaleProbeTask: Task<Void, Never>?

    /// Re-probe Tailscale and reconcile the daemon client. The live-
    /// mode pipeline (webhook server, tunnel, registrations) now runs
    /// in the shipyard CLI as `shipyard daemon`; this method is the
    /// GUI-side driver that decides whether to spawn + subscribe.
    /// Safe to call from anywhere — handles its own @MainActor hop.
    func reconcileLiveMode() async {
        let probe = await TailscaleProbe.probe()
        await MainActor.run {
            self.tailscaleStatus = probe
        }
        await liveController.reconcile(
            mode: liveUpdateMode,
            tailscale: probe,
            repos: Set(ships.map(\.repo)).filter { !$0.isEmpty }.union(knownRepos)
        )
        await MainActor.run {
            self.applyLiveStatus(self.liveController.status)
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
    ///
    /// IMPORTANT: webhooks already carry the authoritative state for
    /// the thing that changed. We must NOT shell out to `gh api` in
    /// response — a busy PR can easily fire 50+ workflow_run/job
    /// events per hour, and one `gh api` call per event obliterates
    /// the 5,000/hr user rate-limit within a day.
    ///
    /// So: mutate the in-memory caches directly from the payload.
    /// The next TTL-gated poll fills in anything we couldn't reconstruct
    /// from the webhook alone.
    /// Internal for tests — see LiveModeRateLimitTests.
    func apply(webhookEvent event: WebhookEvent) {
        switch event {
        case .workflowRun(let p):
            mergeWebhookRun(p)
        case .workflowJob(let p):
            mergeWebhookJob(p)
        case .pullRequest(let p):
            mergeWebhookPullRequest(p)
        case .stateArchived(let p):
            mergeStateArchived(p)
        case .unhandled:
            break
        }
    }

    /// Patch the cached `GitHubRun` in place from a workflow_run
    /// webhook payload. Zero `gh api` calls.
    private func mergeWebhookRun(_ p: WebhookEvent.WorkflowRunPayload) {
        let now = Date()
        let patched = patchCachedRun(runId: p.runId, repo: p.repo, branch: p.headBranch) { old in
            GitHubRun(
                id: old.id,
                repo: old.repo,
                workflowName: old.workflowName,
                headBranch: old.headBranch,
                headSha: old.headSha,
                status: p.status,
                conclusion: p.conclusion,
                url: old.url,
                createdAt: old.createdAt,
                updatedAt: now
            )
        }
        guard !patched else { return }
        let run = GitHubRun(
            id: p.runId,
            repo: p.repo,
            workflowName: p.workflowName,
            headBranch: p.headBranch,
            headSha: p.headSha,
            status: p.status,
            conclusion: p.conclusion,
            url: p.htmlURL.flatMap(URL.init(string:)),
            createdAt: now,
            updatedAt: now
        )
        upsertCachedRun(run)
    }

    /// Patch the cached `GitHubJob` in place from a workflow_job
    /// webhook payload. Zero `gh api` calls.
    private func mergeWebhookJob(_ p: WebhookEvent.WorkflowJobPayload) {
        var jobs = jobsByRunId[p.runId] ?? []
        if let idx = jobs.firstIndex(where: { $0.databaseId == p.jobId }) {
            let old = jobs[idx]
            jobs[idx] = GitHubJob(
                databaseId: old.databaseId,
                name: old.name,
                status: p.status,
                conclusion: p.conclusion,
                labels: p.labels.isEmpty ? old.labels : p.labels,
                runnerName: p.runnerName ?? old.runnerName
            )
        } else {
            jobs.append(GitHubJob(
                databaseId: p.jobId,
                name: p.name,
                status: p.status,
                conclusion: p.conclusion,
                labels: p.labels.isEmpty ? nil : p.labels,
                runnerName: p.runnerName
            ))
        }
        jobsByRunId[p.runId] = jobs
    }

    private func upsertCachedRun(_ run: GitHubRun) {
        var repoRuns = githubRunsByRepo[run.repo] ?? []
        upsertCachedRun(run, in: &repoRuns)
        githubRunsByRepo[run.repo] = repoRuns

        let key = "\(run.repo)\t\(run.headBranch)"
        var branchRuns = githubRunsByBranch[key] ?? []
        upsertCachedRun(run, in: &branchRuns)
        githubRunsByBranch[key] = branchRuns
    }

    private func upsertCachedRun(_ run: GitHubRun, in runs: inout [GitHubRun]) {
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            runs[idx] = run
        } else {
            runs.append(run)
            runs.sort { $0.createdAt > $1.createdAt }
        }
    }

    private func updatedCachedRun(
        _ runId: Int64,
        repo: String,
        branch: String,
        transform: (GitHubRun) -> GitHubRun
    ) -> Bool {
        var changed = false
        if var runs = githubRunsByRepo[repo],
           let idx = runs.firstIndex(where: { $0.id == runId }) {
            runs[idx] = transform(runs[idx])
            githubRunsByRepo[repo] = runs
            changed = true
        }
        let key = "\(repo)\t\(branch)"
        if var runs = githubRunsByBranch[key],
           let idx = runs.firstIndex(where: { $0.id == runId }) {
            runs[idx] = transform(runs[idx])
            githubRunsByBranch[key] = runs
            changed = true
        }
        return changed
    }

    /// Rewrite the run matching `runId` in both caches (repo-wide +
    /// branch-scoped) using the caller's transformer.
    @discardableResult
    private func patchCachedRun(
        runId: Int64,
        repo: String,
        branch: String,
        transform: (GitHubRun) -> GitHubRun
    ) -> Bool {
        updatedCachedRun(runId, repo: repo, branch: branch, transform: transform)
    }

    /// Build `PRState` directly from the pull_request webhook payload.
    /// Skips the `gh pr view` call entirely.
    private func mergeWebhookPullRequest(_ p: WebhookEvent.PullRequestPayload) {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        func parse(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            return fmt.date(from: s) ?? fallback.date(from: s)
        }
        let upperState: String
        if p.merged { upperState = "MERGED" }
        else if p.state == "closed" { upperState = "CLOSED" }
        else { upperState = "OPEN" }
        let key = prKey(repo: p.repo, pr: p.number)
        prStateByKey[key] = PRState(
            state: upperState,
            isMerged: p.merged,
            mergedAt: parse(p.mergedAt),
            closedAt: parse(p.closedAt)
        )
    }

    private func mergeStateArchived(_ p: WebhookEvent.StateArchivedPayload) {
        let key = prKey(repo: p.repo, pr: p.pr)
        if prStateByKey[key] == nil {
            prStateByKey[key] = PRState(
                state: "CLOSED",
                isMerged: false,
                mergedAt: nil,
                closedAt: Date()
            )
        }
        lastRawSnapshot.removeAll { ship in
            ship.prNumber == p.pr && (p.repo.isEmpty || ship.repo == p.repo)
        }
        ships.removeAll { ship in
            ship.prNumber == p.pr && (p.repo.isEmpty || ship.repo == p.repo)
        }
        prExpansionState.removeValue(forKey: p.pr)
        reapplyAutoClearFilter()
        detectBadgeTransition()
    }

    @Published var showGitHubActions: Bool = UserDefaults.standard.object(forKey: Keys.showGitHubActions) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showGitHubActions, forKey: Keys.showGitHubActions)
            if showGitHubActions {
                if deferredStartupWorkStarted {
                    startGitHubPolling()
                    enrichmentGeneration += 1
                    scheduleDeferredLiveStartup()
                }
            } else {
                stopGitHubPolling()
                cancelGitHubDetailWork()
                githubRunsByRepo = [:]
                githubRunsByBranch = [:]
                jobsByRunId = [:]
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
    @Published var namespaceInstances: [NamespaceInstance] = []
    @Published var namespaceDetailsByInstanceID: [String: NamespaceInstanceDetail] = [:]
    @Published private(set) var namespaceDetailErrorsByInstanceID: [String: String] = [:]
    @Published private(set) var namespaceActivityUpdatedAt: Date?
    @Published private(set) var namespaceActivityError: String?
    @Published private(set) var namespaceWorkspaceSlug: String?

    /// Latest REST rate-limit snapshot, polled every 2 min. Drives
    /// the exhaustion banner in ShipsView. `nil` until the first
    /// probe completes.
    @Published private(set) var githubRateLimit: GitHubRateLimit?
    private var rateLimitTask: Task<Void, Never>?
    private var namespaceActivityTask: Task<Void, Never>?
    private var namespaceDetailTasks: [String: Task<Void, Never>] = [:]
    private var deferredStartupTask: Task<Void, Never>?
    private var deferredLiveStartupTask: Task<Void, Never>?
    private var hasOpenedPopover = false
    private var deferredStartupWorkStarted = false
    @Published var enrichmentGeneration: Int = 0

    func startRateLimitPolling() {
        rateLimitTask?.cancel()
        rateLimitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                if let snapshot = await GitHubRateLimitPoller.fetch() {
                    await MainActor.run { self?.githubRateLimit = snapshot }
                }
                // 2 min — /rate_limit itself is free (doesn't count
                // against the user's budget), so frequent checks are
                // safe. The banner needs to refresh reset-in-N-min
                // countdown periodically anyway.
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }

    func stopRateLimitPolling() {
        rateLimitTask?.cancel()
        rateLimitTask = nil
    }

    func startNamespaceActivityPolling() {
        namespaceActivityTask?.cancel()
        namespaceActivityTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await NamespaceActivityPoller.fetch()
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.namespaceInstances = snapshot.instances
                    self?.namespaceWorkspaceSlug = snapshot.workspaceSlug ?? self?.namespaceWorkspaceSlug
                    self?.pruneNamespaceDetails(to: snapshot.instances)
                    self?.namespaceActivityError = snapshot.error
                    self?.namespaceActivityUpdatedAt = Date()
                    self?.fetchJobsForNamespaceCandidates()
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func stopNamespaceActivityPolling() {
        namespaceActivityTask?.cancel()
        namespaceActivityTask = nil
        cancelNamespaceDetailFetches()
    }

    func fetchNamespaceDetailIfNeeded(for instance: NamespaceInstance) {
        let id = instance.id
        guard namespaceDetailsByInstanceID[id] == nil,
              namespaceDetailErrorsByInstanceID[id] == nil,
              namespaceDetailTasks[id] == nil
        else { return }

        namespaceDetailTasks[id] = Task { [weak self] in
            let snapshot = await NamespaceActivityPoller.fetchDetail(instanceID: id)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.namespaceDetailTasks[id] = nil
                if let detail = snapshot.detail {
                    self.namespaceDetailsByInstanceID[id] = detail
                    self.namespaceDetailErrorsByInstanceID.removeValue(forKey: id)
                } else {
                    self.namespaceDetailErrorsByInstanceID[id] = snapshot.error ?? "could not load Namespace instance detail"
                }
            }
        }
    }

    func refreshNamespaceDetail(for instance: NamespaceInstance) {
        namespaceDetailTasks[instance.id]?.cancel()
        namespaceDetailTasks[instance.id] = nil
        namespaceDetailsByInstanceID.removeValue(forKey: instance.id)
        namespaceDetailErrorsByInstanceID.removeValue(forKey: instance.id)
        fetchNamespaceDetailIfNeeded(for: instance)
    }

    private func pruneNamespaceDetails(to instances: [NamespaceInstance]) {
        let liveIDs = Set(instances.map(\.id))
        namespaceDetailsByInstanceID = namespaceDetailsByInstanceID.filter { liveIDs.contains($0.key) }
        namespaceDetailErrorsByInstanceID = namespaceDetailErrorsByInstanceID.filter { liveIDs.contains($0.key) }
        for id in Array(namespaceDetailTasks.keys) where !liveIDs.contains(id) {
            namespaceDetailTasks[id]?.cancel()
            namespaceDetailTasks[id] = nil
        }
    }

    private func cancelNamespaceDetailFetches() {
        for task in namespaceDetailTasks.values {
            task.cancel()
        }
        namespaceDetailTasks.removeAll()
    }

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
        liveController.onStatusChange = { [weak self] newStatus in
            Task { @MainActor in
                self?.applyLiveStatus(newStatus)
            }
        }
        liveController.onEvent = { [weak self] event in
            self?.apply(webhookEvent: event)
        }
        if liveUpdateMode == .off {
            liveStatus = .polling(reason: .userDisabled)
        } else {
            scheduleDeferredLiveStartup()
        }
        syncLaunchAtLoginFromSystem()
    }

    private func applyLiveStatus(_ newStatus: LiveUpdateStatus) {
        liveStatus = newStatus
        liveStartupPending = false
        if newStatus.blocksGitHubAPIPolling {
            cancelGitHubDetailWork()
        }
    }

    /// Called by the status-item host after the popover is visible.
    /// Keep launch cheap: the first click should paint UI immediately,
    /// then enrich in the background after AppKit has opened the menu.
    func notePopoverOpened() {
        hasOpenedPopover = true
        guard !deferredStartupWorkStarted else {
            if showGitHubActions {
                startGitHubPolling()
            }
            return
        }
        deferredStartupTask?.cancel()
        deferredStartupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.startDeferredStartupWork()
            }
        }
    }

    func notePopoverClosed() {
        if !deferredStartupWorkStarted {
            deferredStartupTask?.cancel()
            deferredStartupTask = nil
            hasOpenedPopover = false
        }
        // Keep the live daemon subscription warm while the popover is
        // closed. Webhook updates are app-lifecycle state; expensive
        // GitHub polling/detail enrichment is popover-lifecycle work.
        stopGitHubPolling()
        cancelGitHubDetailWork()
    }

    func shutdown() {
        deferredStartupTask?.cancel()
        deferredStartupTask = nil
        deferredLiveStartupTask?.cancel()
        deferredLiveStartupTask = nil
        tailscaleProbeTask?.cancel()
        tailscaleProbeTask = nil
        stopGitHubPolling()
        stopRateLimitPolling()
        stopNamespaceActivityPolling()
        cancelGitHubDetailWork()
        let oldPipeline = pipeline
        pipeline = nil
        Task {
            await oldPipeline?.stop()
            await liveController.stop()
        }
    }

    private func startDeferredStartupWork() {
        guard hasOpenedPopover, !deferredStartupWorkStarted else { return }
        deferredStartupWorkStarted = true
        if cliBinaryResolved != nil {
            Task { [weak self] in await self?.runDoctor() }
        }
        if showGitHubActions {
            startGitHubPolling()
            startRateLimitPolling()
        }
        startNamespaceActivityPolling()
        enrichmentGeneration += 1
    }

    private var hasStartedLiveStartup = false

    private func scheduleDeferredLiveStartup(after delay: UInt64 = 3_000_000_000) {
        guard !hasStartedLiveStartup else { return }
        guard liveUpdateMode != .off else {
            liveStartupPending = false
            liveStatus = .polling(reason: .userDisabled)
            return
        }
        guard deferredLiveStartupTask == nil else {
            markLiveStartupPendingIfNeeded()
            return
        }
        markLiveStartupPendingIfNeeded()
        deferredLiveStartupTask?.cancel()
        deferredLiveStartupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.deferredLiveStartupTask = nil
                self?.startLiveStartup()
            }
        }
    }

    private func startLiveStartup() {
        guard !hasStartedLiveStartup else { return }
        guard liveUpdateMode != .off else {
            liveStartupPending = false
            liveStatus = .polling(reason: .userDisabled)
            return
        }
        hasStartedLiveStartup = true
        liveStartupPending = true
        Task { [weak self] in
            await self?.reconcileLiveMode()
            await MainActor.run { self?.startTailscaleWatcher() }
        }
    }

    private func markLiveStartupPendingIfNeeded() {
        guard liveUpdateMode != .off else {
            liveStartupPending = false
            liveStatus = .polling(reason: .userDisabled)
            return
        }
        if case .live = liveStatus {
            return
        }
        liveStartupPending = true
        liveStatus = .polling(reason: nil)
    }

    /// Reconcile the stored `launchAtLogin` preference with the OS's
    /// view. The user can flip the switch in System Settings →
    /// General → Login Items at any time; we want the Settings toggle
    /// in Shipyard to reflect that truth on launch. No registration
    /// mutation happens here — we read state only.
    private func syncLaunchAtLoginFromSystem() {
        let enabled = (SMAppService.mainApp.status == .enabled)
        if enabled != launchAtLogin {
            // Bypass the didSet (which would call register/unregister
            // redundantly) by setting the backing UserDefault and
            // publishing the new value.
            UserDefaults.standard.set(enabled, forKey: Keys.launchAtLogin)
            launchAtLoginSuppressDidSet = true
            launchAtLogin = enabled
            launchAtLoginSuppressDidSet = false
        }
    }

    /// Apply the current `launchAtLogin` preference to the system
    /// login-items registry. Failures are surfaced via `cliBinaryError`
    /// so the Settings row can show a one-line warning without a modal.
    private func applyLaunchAtLoginRegistration() {
        if launchAtLoginSuppressDidSet { return }
        do {
            let service = SMAppService.mainApp
            if launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            // Registration can fail if the user has previously denied
            // the request (status becomes `.requiresApproval`). We
            // leave the published toggle in the user-chosen state so
            // they can see what they asked for; the Settings view
            // renders a hint pointing at System Settings when the
            // system status drifts from the toggle.
            NSLog("Shipyard: launchAtLogin mutation failed: %@",
                  error.localizedDescription)
        }
    }

    /// Guard that stops the `launchAtLogin.didSet` from trying to
    /// re-register when we're just absorbing a system-side change on
    /// launch. Not @Published — purely internal bookkeeping.
    private var launchAtLoginSuppressDidSet: Bool = false

    /// Sparkle wrapper, injected by AppDelegate after the store is
    /// constructed. Settings binds the "Check for Updates…" button
    /// to this. Optional so unit tests don't have to stand up a full
    /// Sparkle stack.
    var autoUpdate: AutoUpdateController?

    /// OS-level truth for the login-item registration. The Settings
    /// view surfaces this alongside the toggle so the user can see if
    /// macOS has declined / requires approval / is enabled.
    var launchAtLoginSystemStatus: SMAppService.Status {
        SMAppService.mainApp.status
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
        // Empty-targets ships report .pending even when their GH
        // runs have all completed. Use the derived status so the
        // "failed" pill on the card matches what clearCompleted acts
        // on.
        if let derived = derivedStatusFromGitHub(for: ship),
           derived == .passed || derived == .failed {
            return true
        }
        return false
    }

    /// Nuclear "Clear all" — dismiss every tracked PR regardless of
    /// state. Mirrors the per-card hide button, applied in bulk.
    /// Reversible via "Show N hidden" until the user quits the app.
    func clearAll() {
        for index in ships.indices where !ships[index].dismissed {
            ships[index].dismissed = true
        }
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
        if let candidate = ShipyardProcessEnvironment.findExecutable(
            named: "shipyard",
            candidates: candidates
        ) {
            cliBinaryResolved = candidate
            cliBinaryError = nil
            return
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

        // Cache the unfiltered list so auto-clear setting changes can
        // re-run the filter without forcing a fresh poll (which costs
        // ~5-6s for the CLI cold start).
        lastRawSnapshot = updated
        // Flag the initial pipeline snapshot so the empty-state view
        // can switch from spinner → empty-copy once we've actually
        // heard back (even if we heard back "nothing").
        hasLoadedInitialShips = true
        // Auto-clear stale terminal ships. Delegated to
        // `reapplyAutoClearFilter` so setting changes can re-run it
        // against `lastRawSnapshot` without a full snapshot cycle.
        reapplyAutoClearFilter()
        let previousRepos = knownRepos
        knownRepos.formUnion(updated.map(\.repo).filter { !$0.isEmpty })
        // If the snapshot surfaced new repos after live mode
        // reconciled at launch (empty-repo race), re-run reconcile
        // so webhooks get registered on them.
        if knownRepos != previousRepos {
            if deferredStartupWorkStarted {
                Task { [weak self] in await self?.reconcileLiveMode() }
            }
        }
        reseedAutoExpand()
        detectBadgeTransition()
    }

    /// Re-run the auto-clear filter against the cached raw snapshot
    /// and publish the resulting `ships` + `hiddenStaleCount`.
    ///
    /// Called from two places:
    ///   1. `applySnapshot`, after caching the raw `updated` list.
    ///   2. `didSet` on `autoClearPassedMinutes`/`autoClearFailedMinutes`
    ///      so a settings toggle re-filters immediately instead of
    ///      waiting up to ~12s for the next 7s poll + 5-6s CLI cold
    ///      start to land a fresh snapshot.
    ///
    /// "Terminal" includes `overallStatus == .passed / .failed` OR PR
    /// state is `merged / closed`. Ships with empty targets (and
    /// therefore `.pending` status) would otherwise never age out
    /// even when their PR merged long ago — the merged signal from PR
    /// state catches them.
    private func reapplyAutoClearFilter() {
        let now = Date()
        var hidden = 0
        let filtered = lastRawSnapshot.filter { ship in
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
        ships = (showStale ? lastRawSnapshot : filtered)
            .sorted { a, b in
                let ap = activityRank(for: a)
                let bp = activityRank(for: b)
                if ap != bp { return ap < bp }
                return a.startedAt > b.startedAt
            }
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
                let shouldPoll = await MainActor.run {
                    self?.shouldPollGitHubActionsNow ?? false
                }
                if shouldPoll {
                    await self?.pollGitHubOnce()
                }
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
        Self.pollIntervalNanoseconds(for: liveStatus)
    }

    nonisolated static func pollIntervalNanoseconds(for status: LiveUpdateStatus) -> UInt64 {
        if status.usesConservativeGitHubPollingCadence { return 300_000_000_000 }
        return 60_000_000_000
    }

    @MainActor
    var shouldPollGitHubActionsNow: Bool {
        Self.shouldPollGitHubActions(
            showGitHubActions: showGitHubActions,
            liveStartupPending: liveStartupPending,
            liveStatus: liveStatus,
            rateLimitExceeded: githubRateLimit?.isExceeded == true
        )
    }

    nonisolated static func shouldPollGitHubActions(
        showGitHubActions: Bool,
        liveStartupPending: Bool,
        liveStatus: LiveUpdateStatus,
        rateLimitExceeded: Bool
    ) -> Bool {
        guard showGitHubActions else { return false }
        guard !liveStartupPending else { return false }
        guard !liveStatus.blocksGitHubAPIPolling else { return false }
        guard !rateLimitExceeded else { return false }
        return true
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
                    // Job detail is now row-driven. Repo polling should
                    // update run status cheaply; fan-out `gh run view`
                    // calls are deferred until the user opens rows that
                    // actually need provider/job details.
                    self.reseedAutoExpand()
                }
            }
        }
    }

    /// The set of GitHubRun IDs currently owned by any tracked ship in
    /// this repo — matched by branch or head_sha. Used to scope
    /// automatic job fetches to just the ones that feed platform-dot
    /// rendering. Unrelated runs get their jobs lazily when the user
    /// expands "Other GitHub Actions runs."
    private func ownedRunIds(for repo: String) -> Set<Int64> {
        let shipsInRepo = ships.filter { !$0.dismissed && $0.repo == repo }
        guard !shipsInRepo.isEmpty else { return [] }
        let runs = githubRunsByRepo[repo] ?? []
        var owned: Set<Int64> = []
        for run in runs {
            for ship in shipsInRepo {
                let branchMatch = !ship.branch.isEmpty && run.headBranch == ship.branch
                let shaMatch = !ship.headSha.isEmpty && run.headSha == ship.headSha
                if branchMatch || shaMatch {
                    owned.insert(run.id)
                    break
                }
            }
        }
        return owned
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
    private var branchFetchTasks: [String: Task<Void, Never>] = [:]
    private var pendingBranchFetches: [Ship] = []
    private let maxConcurrentBranchFetches = 1

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
        guard deferredStartupWorkStarted || force else { return }
        guard shouldPollGitHubActionsNow else { return }
        guard showGitHubActions,
              !ship.repo.isEmpty,
              !ship.branch.isEmpty else { return }
        let repo = ship.repo
        let branch = ship.branch
        let key = "\(repo)\t\(branch)"
        if inflightBranchFetches.contains(key) { return }
        if pendingBranchFetches.contains(where: { "\($0.repo)\t\($0.branch)" == key }) {
            return
        }
        if !force,
           let last = lastBranchFetch[key],
           Date().timeIntervalSince(last) < branchFetchTTL {
            return
        }
        if inflightBranchFetches.count >= maxConcurrentBranchFetches {
            pendingBranchFetches.append(ship)
            return
        }
        startBranchFetch(repo: repo, branch: branch, key: key)
    }

    private func startBranchFetch(repo: String, branch: String, key: String) {
        inflightBranchFetches.insert(key)
        let task = Task { [weak self] in
            let runs = await GitHubActionsPoller.fetch(
                repo: repo, branch: branch, limit: 50
            )
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                defer {
                    self.inflightBranchFetches.remove(key)
                    self.branchFetchTasks.removeValue(forKey: key)
                    self.drainBranchFetchQueue()
                }
                self.lastBranchFetch[key] = Date()
                guard let runs else { return }
                let previous = self.githubRunsByBranch[key] ?? []
                self.githubRunsByBranch[key] = runs
                self.reconcileJobsCache(newRuns: runs, oldRuns: previous)
                self.reseedAutoExpand()
            }
        }
        branchFetchTasks[key] = task
    }

    private func drainBranchFetchQueue() {
        while inflightBranchFetches.count < maxConcurrentBranchFetches,
              !pendingBranchFetches.isEmpty {
            let next = pendingBranchFetches.removeFirst()
            guard !next.repo.isEmpty, !next.branch.isEmpty else { continue }
            let key = "\(next.repo)\t\(next.branch)"
            if inflightBranchFetches.contains(key) { continue }
            if let last = lastBranchFetch[key],
               Date().timeIntervalSince(last) < branchFetchTTL {
                continue
            }
            startBranchFetch(repo: next.repo, branch: next.branch, key: key)
        }
    }

    // MARK: - PR state on github.com

    /// Cache of PR state from github.com. Keyed by "repo\tpr".
    /// Absent = not fetched; present = fetched.
    @Published var prStateByKey: [String: PRState] = [:]
    private var inflightPRStateFetches: Set<String> = []
    /// Last attempt timestamp per PR key — guards against retry storms
    /// when the GitHub fallback fails (e.g. during a rate-limit window).
    /// With a five-minute cooldown, visible cards can still self-heal
    /// stale PR state without draining GitHub's hourly API budget.
    private var lastPRStateFetchAttempt: [String: Date] = [:]
    private let prStateFetchCooldown: TimeInterval = 5 * 60
    private var prStateFetchTasks: [String: Task<Void, Never>] = [:]
    private var pendingPRStateFetches: [Ship] = []
    private let maxConcurrentPRStateFetches = 1

    private func prKey(repo: String, pr: Int) -> String { "\(repo)\t\(pr)" }

    func prState(for ship: Ship) -> PRState? {
        prStateByKey[prKey(repo: ship.repo, pr: ship.prNumber)]
    }

    func fetchPRStateIfNeeded(for ship: Ship) {
        guard deferredStartupWorkStarted else { return }
        guard shouldPollGitHubActionsNow else { return }
        let key = prKey(repo: ship.repo, pr: ship.prNumber)
        if prStateByKey[key] != nil { return }
        if inflightPRStateFetches.contains(key) { return }
        if pendingPRStateFetches.contains(where: { prKey(repo: $0.repo, pr: $0.prNumber) == key }) {
            return
        }
        if let last = lastPRStateFetchAttempt[key],
           Date().timeIntervalSince(last) < prStateFetchCooldown {
            return
        }
        if inflightPRStateFetches.count >= maxConcurrentPRStateFetches {
            pendingPRStateFetches.append(ship)
            return
        }
        startPRStateFetch(ship: ship, key: key)
    }

    private func startPRStateFetch(ship: Ship, key: String) {
        inflightPRStateFetches.insert(key)
        lastPRStateFetchAttempt[key] = Date()
        let repo = ship.repo
        let pr = ship.prNumber
        let task = Task { [weak self] in
            let state = await PRStatePoller.fetch(repo: repo, pr: pr)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.finishPRStateFetch(key: key, state: state)
            }
        }
        prStateFetchTasks[key] = task
    }

    private func finishPRStateFetch(key: String, state: PRState?) {
        if let state {
            prStateByKey[key] = state
        }
        inflightPRStateFetches.remove(key)
        prStateFetchTasks.removeValue(forKey: key)
        if state != nil {
            reseedAutoExpand()
        }
        drainPRStateFetchQueue()
    }

    private func drainPRStateFetchQueue() {
        while inflightPRStateFetches.count < maxConcurrentPRStateFetches,
              !pendingPRStateFetches.isEmpty {
            let next = pendingPRStateFetches.removeFirst()
            let key = prKey(repo: next.repo, pr: next.prNumber)
            if prStateByKey[key] != nil { continue }
            if inflightPRStateFetches.contains(key) { continue }
            if let last = lastPRStateFetchAttempt[key],
               Date().timeIntervalSince(last) < prStateFetchCooldown {
                continue
            }
            startPRStateFetch(ship: next, key: key)
        }
    }

    // MARK: - Per-run job details (runner provider)

    /// Keyed by run id. Populated by fetchJobsIfNeeded and read by
    /// views. Absence means "not fetched yet"; empty array means
    /// "fetched, but no jobs."
    @Published var jobsByRunId: [Int64: [GitHubJob]] = [:]
    private var inflightJobFetches: Set<Int64> = []
    private var jobFetchTasks: [Int64: Task<Void, Never>] = [:]
    private var pendingJobFetches: [GitHubRun] = []
    private let maxConcurrentJobFetches = 2

    func fetchJobsIfNeeded(for run: GitHubRun) {
        guard deferredStartupWorkStarted else { return }
        guard shouldPollGitHubActionsNow else { return }
        if jobsByRunId[run.id] != nil { return }
        if inflightJobFetches.contains(run.id) { return }
        if pendingJobFetches.contains(where: { $0.id == run.id }) { return }
        if inflightJobFetches.count >= maxConcurrentJobFetches {
            pendingJobFetches.append(run)
            return
        }
        startJobFetch(run)
    }

    private func startJobFetch(_ run: GitHubRun) {
        inflightJobFetches.insert(run.id)
        let repo = run.repo
        let id = run.id
        let task = Task { [weak self] in
            let jobs = await GitHubActionsPoller.fetchJobs(repo: repo, runId: id) ?? []
            if Task.isCancelled { return }
            await MainActor.run {
                self?.finishJobFetch(id: id, jobs: jobs)
            }
        }
        jobFetchTasks[id] = task
    }

    private func finishJobFetch(id: Int64, jobs: [GitHubJob]) {
        jobsByRunId[id] = jobs
        inflightJobFetches.remove(id)
        jobFetchTasks.removeValue(forKey: id)
        reseedAutoExpand()
        drainJobFetchQueue()
    }

    private func drainJobFetchQueue() {
        while inflightJobFetches.count < maxConcurrentJobFetches,
              !pendingJobFetches.isEmpty {
            let next = pendingJobFetches.removeFirst()
            if jobsByRunId[next.id] != nil { continue }
            if inflightJobFetches.contains(next.id) { continue }
            startJobFetch(next)
        }
    }

    private func cancelGitHubDetailWork() {
        for task in prStateFetchTasks.values { task.cancel() }
        prStateFetchTasks.removeAll()
        inflightPRStateFetches.removeAll()
        pendingPRStateFetches.removeAll()

        for task in branchFetchTasks.values { task.cancel() }
        branchFetchTasks.removeAll()
        inflightBranchFetches.removeAll()
        pendingBranchFetches.removeAll()

        for task in jobFetchTasks.values { task.cancel() }
        jobFetchTasks.removeAll()
        inflightJobFetches.removeAll()
        pendingJobFetches.removeAll()
    }

    /// Best-effort runner-provider summary for a run: the distinct set
    /// of providers across its jobs. Returns nil if we haven't fetched
    /// yet; empty array if the run has no jobs (rare).
    func providers(for run: GitHubRun) -> [String]? {
        guard let jobs = jobsByRunId[run.id] else { return nil }
        let uniq = Array(Set(jobs.map(\.provider))).sorted()
        return uniq
    }

    func visibleNamespaceInstances() -> [NamespaceInstance] {
        namespaceInstances.sorted { $0.createdAt > $1.createdAt }
    }

    func namespaceJobContext(for instance: NamespaceInstance) -> NamespaceInstanceJobContext? {
        for run in allCachedGitHubRuns() {
            guard let jobs = jobsByRunId[run.id] else { continue }
            for job in jobs where job.namespaceInstanceID == instance.id {
                return NamespaceInstanceJobContext(
                    repo: run.repo,
                    workflowName: run.workflowName,
                    jobName: job.name,
                    branch: run.headBranch,
                    headSha: run.headSha,
                    runID: run.id,
                    jobID: job.databaseId,
                    githubURL: URL(string: "https://github.com/\(run.repo)/actions/runs/\(run.id)/job/\(job.databaseId)"),
                    namespaceURL: namespaceWorkspaceSlug.flatMap {
                        URL(string: "https://cloud.namespace.so/\($0)/actions/job/\(job.databaseId)")
                    }
                )
            }
        }
        return nil
    }

    func fetchJobsForNamespaceCandidates() {
        guard deferredStartupWorkStarted, shouldPollGitHubActionsNow else { return }
        let instanceIDs = Set(namespaceInstances.map(\.id))
        guard !instanceIDs.isEmpty else { return }

        let candidateRuns = allCachedGitHubRuns()
            .filter(\.isRunning)
            .filter { run in
                run.repo.isEmpty || namespaceInstances.contains(where: { $0.repo == run.repo })
            }
            .sorted { $0.createdAt > $1.createdAt }

        for run in candidateRuns.prefix(max(8, instanceIDs.count * 2)) {
            fetchJobsIfNeeded(for: run)
        }
    }

    private func allCachedGitHubRuns() -> [GitHubRun] {
        var seen: Set<Int64> = []
        var runs: [GitHubRun] = []
        for source in Array(githubRunsByRepo.values) + Array(githubRunsByBranch.values) {
            for run in source where seen.insert(run.id).inserted {
                runs.append(run)
            }
        }
        return runs
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
        static let launchAtLogin = "launchAtLogin"
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
        ShipyardProcessEnvironment.findExecutable(named: "gh", candidates: [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ])
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
