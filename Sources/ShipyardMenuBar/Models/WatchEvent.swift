import Foundation

/// Matches the NDJSON schema emitted by `shipyard watch --json --follow`.
/// See docs/ARCHITECTURE.md for the canonical shape.
struct WatchEvent: Decodable {
    let event: String
    let pr: Int?
    let headSha: String?
    let attempt: Int?
    let evidence: [String: EvidenceValue]?
    let dispatchedRuns: [DispatchedRun]?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case event, pr, attempt, evidence
        case headSha = "head_sha"
        case dispatchedRuns = "dispatched_runs"
        case updatedAt = "updated_at"
    }

    /// `evidence: {target: "pass"}` or `evidence: {target: {"status": "reused", "reused_from": "..."}}`
    enum EvidenceValue: Decodable {
        case plain(String)
        case reused(from: String)

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let str = try? container.decode(String.self) {
                self = .plain(str)
                return
            }
            let container = try decoder.container(keyedBy: DynamicKey.self)
            let status = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "status"))
            let from = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "reused_from"))
            if status == "reused", let from {
                self = .reused(from: from)
            } else {
                self = .plain(status ?? "pending")
            }
        }

        private struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        var status: TargetStatus {
            switch self {
            case .plain(let s):
                switch s {
                case "pass": return .passed
                case "fail": return .failed
                case "reused": return .reused
                default: return .pending
                }
            case .reused: return .reused
            }
        }

        var reusedFrom: String? {
            if case .reused(let from) = self { return from }
            return nil
        }
    }

    struct DispatchedRun: Decodable {
        let target: String
        let provider: String
        let runId: String
        let status: String
        let startedAt: Date
        let updatedAt: Date
        let attempt: Int?
        let lastHeartbeatAt: Date?
        let phase: String?
        let elapsedSeconds: Int?
        let required: Bool?

        enum CodingKeys: String, CodingKey {
            case target, provider, status, attempt, phase, required
            case runId = "run_id"
            case startedAt = "started_at"
            case updatedAt = "updated_at"
            case lastHeartbeatAt = "last_heartbeat_at"
            case elapsedSeconds = "elapsed_seconds"
        }
    }
}

// MARK: - Decoder helpers

extension JSONDecoder {
    static let shipyard: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // Shipyard emits ISO-8601 with microseconds in UTC. Try
            // fractional-seconds first, fall back to plain ISO.
            let formatters: [ISO8601DateFormatter] = [
                {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }(),
                {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime]
                    return f
                }(),
            ]
            for f in formatters {
                if let date = f.date(from: raw) { return date }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable ISO-8601 date: \(raw)"
            )
        }
        return d
    }()
}

// MARK: - Merge into Ship

extension WatchEvent {
    /// Apply this event to an existing `Ship`, returning the updated copy.
    /// A `nil` return means the event was terminal (pr-not-found, state-archived)
    /// and the ship should be removed.
    func apply(to ship: Ship?) -> Ship? {
        switch event {
        case "pr-not-found", "state-archived":
            return nil
        case "update", "no-active-ship":
            break
        default:
            // Forward-compat: unknown event types leave state alone.
            return ship
        }

        guard let pr, let headSha else { return ship }

        let existing = ship ?? Ship(
            id: "pr-\(pr)",
            repo: "",
            prNumber: pr,
            branch: "",
            worktree: "",
            headSha: headSha,
            targets: [],
            autoMerge: false,
            dismissed: false,
            startedAt: updatedAt ?? Date()
        )

        var updated = existing
        updated.headSha = headSha

        // Build target map by name so we can merge evidence + dispatched_runs
        // from both sides of the NDJSON payload.
        var targets: [String: Target] = Dictionary(
            uniqueKeysWithValues: existing.targets.map { ($0.name, $0) }
        )

        for run in dispatchedRuns ?? [] {
            var t = targets[run.target] ?? Target(name: run.target)
            t.status = Self.statusFromRunString(run.status, targetStatus: t.status)
            t.phase = Phase(rawValue: run.phase ?? "") ?? t.phase
            t.elapsedSeconds = run.elapsedSeconds ?? t.elapsedSeconds
            if let hb = run.lastHeartbeatAt {
                t.heartbeatAgeSeconds = max(0, Int(Date().timeIntervalSince(hb)))
            }
            t.advisory = (run.required == false)
            if let prov = RunnerProvider(rawValue: Self.normalizeProvider(run.provider)) {
                t.runner = Runner(provider: prov, label: run.provider, detail: nil)
            }
            targets[run.target] = t
        }

        for (name, value) in evidence ?? [:] {
            var t = targets[name] ?? Target(name: name)
            t.status = value.status
            if let from = value.reusedFrom {
                t.reusedFrom = from
            }
            targets[name] = t
        }

        updated.targets = targets.values.sorted { $0.name < $1.name }
        return updated
    }

    private static func statusFromRunString(_ raw: String, targetStatus: TargetStatus) -> TargetStatus {
        switch raw.lowercased() {
        case "pass", "passed", "success", "completed", "completed_success": return .passed
        case "fail", "failed", "failure", "completed_failure": return .failed
        case "running", "in_progress": return .running
        case "cancelled", "canceled": return .failed
        case "queued", "pending", "waiting": return .pending
        default: return targetStatus
        }
    }

    private static func normalizeProvider(_ raw: String) -> String {
        if raw.hasPrefix("github") { return "github" }
        if raw.hasPrefix("ssh") { return "ssh" }
        if raw.contains("namespace") || raw == "ns" { return "namespace" }
        if raw == "local" { return "local" }
        return raw
    }
}
