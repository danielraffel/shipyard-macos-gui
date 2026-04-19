import Foundation

/// Matches the actual `shipyard --json ship-state list` output. The envelope
/// is `{ "schema_version": 1, "command": "ship-state:list", "states": [...] }`.
struct ShipStateListEntry: Decodable {
    let pr: Int
    let branch: String?
    let baseBranch: String?
    let headSha: String?
    let repo: String?
    let prUrl: String?
    let prTitle: String?
    let commitSubject: String?
    let dispatchedRuns: [WatchEvent.DispatchedRun]?
    let evidenceSnapshot: [String: String]?
    let attempt: Int?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case pr, branch, repo, attempt
        case baseBranch = "base_branch"
        case headSha = "head_sha"
        case prUrl = "pr_url"
        case prTitle = "pr_title"
        case commitSubject = "commit_subject"
        case dispatchedRuns = "dispatched_runs"
        case evidenceSnapshot = "evidence_snapshot"
        case updatedAt = "updated_at"
    }
}

private struct ShipStateListEnvelope: Decodable {
    let states: [ShipStateListEntry]
}

enum ShipStateListPoller {
    static func fetch(binary: String) async -> [ShipStateListEntry]? {
        let raw = await runShipyardCapturingStdout(
            binary: binary,
            args: ["--json", "ship-state", "list"]
        )
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        if let env = try? JSONDecoder.shipyard.decode(ShipStateListEnvelope.self, from: data) {
            return env.states
        }
        // Tolerance for older CLI shapes.
        if let arr = try? JSONDecoder.shipyard.decode([ShipStateListEntry].self, from: data) {
            return arr
        }
        return nil
    }
}

/// Runs `binary args...`, waits for exit, returns stdout as a String.
func runShipyardCapturingStdout(binary: String, args: [String]) async -> String {
    await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                cont.resume(returning: "")
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Ship construction from list entry

extension Ship {
    init(from entry: ShipStateListEntry) {
        self.init(
            id: "pr-\(entry.pr)",
            repo: entry.repo ?? "",
            prNumber: entry.pr,
            branch: entry.branch ?? "",
            worktree: "",
            headSha: entry.headSha ?? "",
            targets: [],
            autoMerge: false,
            dismissed: false,
            startedAt: entry.updatedAt ?? Date()
        )
        if let runs = entry.dispatchedRuns {
            let targetsByName = Dictionary(
                uniqueKeysWithValues: runs.map { run -> (String, Target) in
                    var t = Target(name: run.target)
                    t.status = TargetStatus.from(runStatus: run.status)
                    t.phase = Phase(rawValue: run.phase ?? "") ?? .configure
                    t.elapsedSeconds = run.elapsedSeconds ?? 0
                    if let hb = run.lastHeartbeatAt {
                        t.heartbeatAgeSeconds = max(0, Int(Date().timeIntervalSince(hb)))
                    }
                    t.advisory = (run.required == false)
                    t.runId = run.runId
                    if let prov = RunnerProvider.parse(run.provider) {
                        t.runner = Runner(provider: prov, label: run.provider, detail: nil)
                    }
                    return (run.target, t)
                }
            )
            var merged = targetsByName
            for (name, status) in entry.evidenceSnapshot ?? [:] {
                var t = merged[name] ?? Target(name: name)
                t.status = TargetStatus.from(evidenceStatus: status)
                merged[name] = t
            }
            targets = merged.values.sorted { $0.name < $1.name }
        }
    }
}

extension TargetStatus {
    static func from(runStatus raw: String) -> TargetStatus {
        switch raw.lowercased() {
        case "pass", "passed", "completed", "completed_success", "success": return .passed
        case "fail", "failed", "completed_failure", "failure": return .failed
        case "running", "in_progress": return .running
        case "cancelled", "canceled": return .failed
        default: return .pending
        }
    }
    static func from(evidenceStatus raw: String) -> TargetStatus {
        switch raw.lowercased() {
        case "pass": return .passed
        case "fail": return .failed
        case "reused": return .reused
        default: return .pending
        }
    }
}

extension RunnerProvider {
    static func parse(_ raw: String) -> RunnerProvider? {
        let normalized = raw.lowercased()
        if normalized.hasPrefix("github") { return .github }
        if normalized.hasPrefix("ssh") { return .ssh }
        if normalized.contains("namespace") || normalized == "ns" { return .namespace }
        if normalized == "local" { return .local }
        return nil
    }
}
