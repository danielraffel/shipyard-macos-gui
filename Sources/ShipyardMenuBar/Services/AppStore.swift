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
    }

    func dismiss(ship: Ship) {
        guard let index = ships.firstIndex(where: { $0.id == ship.id }) else { return }
        ships[index].dismissed = true
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

    func clearCompleted() {
        ships.removeAll { $0.overallStatus == .passed || $0.overallStatus == .failed }
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
        for entry in entries {
            var ship = Ship(from: entry)
            if let existing = byPR[entry.pr] {
                ship.dismissed = existing.dismissed
                ship.autoMerge = existing.autoMerge
            }
            updated.append(ship)
        }

        // Auto-clear stale terminal ships. `shipyard ship-state list`
        // returns every state that wasn't explicitly archived, which
        // includes ships from weeks ago. Showing those poisons the
        // overall badge (any old fail → "failed"). Honor the
        // Settings → Auto-clear intervals instead.
        let now = Date()
        var hidden = 0
        let filtered = updated.filter { ship in
            let status = ship.overallStatus
            guard status == .passed || status == .failed else { return true }
            let limit = status == .passed
                ? autoClearPassedMinutes
                : autoClearFailedMinutes
            if limit <= 0 { return true } // 0 / Never
            let ageMinutes = now.timeIntervalSince(ship.startedAt) / 60.0
            if ageMinutes < Double(limit) { return true }
            hidden += 1
            return false
        }

        hiddenStaleCount = hidden
        ships = (showStale ? updated : filtered)
            .sorted { $0.prNumber < $1.prNumber }
        knownRepos.formUnion(updated.map(\.repo).filter { !$0.isEmpty })
        detectBadgeTransition()
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
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            }
        }
    }

    func stopGitHubPolling() {
        githubPollTask?.cancel()
        githubPollTask = nil
    }

    private func pollGitHubOnce() async {
        let repos = await MainActor.run { self.knownRepos }
        for repo in repos {
            if let runs = await GitHubActionsPoller.fetch(repo: repo, limit: 30) {
                await MainActor.run {
                    self.githubRunsByRepo[repo] = runs
                }
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

    /// Triggered by ShipCardView when the card becomes expanded.
    /// Fetches `gh run list --branch <ship.branch>` to backfill runs
    /// that may be outside the repo-wide top-100 window.
    func fetchRunsForShipOnDemand(_ ship: Ship) {
        guard showGitHubActions,
              !ship.repo.isEmpty,
              !ship.branch.isEmpty else { return }
        let repo = ship.repo
        let branch = ship.branch
        Task {
            if let runs = await GitHubActionsPoller.fetch(
                repo: repo, branch: branch, limit: 50
            ) {
                await MainActor.run {
                    self.githubRunsByBranch["\(repo)\t\(branch)"] = runs
                }
            }
        }
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
