import Foundation

// MARK: - Status vocabulary

enum TargetStatus: String, Codable, Equatable, CaseIterable {
    case pending, running, passed, failed, skipped, reused

    var symbol: String {
        switch self {
        case .passed: return "\u{2713}"   // ✓
        case .failed: return "\u{2717}"   // ✗
        case .running: return "\u{25CF}"  // ●
        case .pending: return "\u{25CB}"  // ○
        case .skipped: return "\u{2013}"  // –
        case .reused: return "\u{21BB}"   // ↻
        }
    }
}

enum FailureClass: String, Codable, Equatable {
    case infra = "INFRA"
    case timeout = "TIMEOUT"
    case contract = "CONTRACT"
    case test = "TEST"
    case unknown = "UNKNOWN"
}

enum Phase: String, Codable, Equatable {
    case configure, build, test, package
}

enum RunnerProvider: String, Codable, Equatable, CaseIterable {
    case local, ssh, github, namespace

    var icon: String {
        switch self {
        case .local: return "\u{25C6}"     // ◆
        case .ssh: return "\u{25C7}"       // ◇
        case .github: return "\u{25CF}"    // ●
        case .namespace: return "\u{25CE}" // ◎
        }
    }
}

// MARK: - Data model

struct Runner: Codable, Equatable, Hashable {
    let provider: RunnerProvider
    let label: String
    var detail: String?
}

struct Target: Identifiable, Codable, Equatable {
    let name: String
    var status: TargetStatus = .pending
    var phase: Phase = .configure
    var heartbeatAgeSeconds: Int = 0
    var elapsedSeconds: Int = 0
    var failureClass: FailureClass?
    var runner: Runner?
    var advisory: Bool = false
    var reusedFrom: String?
    /// Identifier shipyard uses for this dispatched run (e.g.
    /// "sy-20260416-726b14"). Needed for `shipyard logs JOB_ID`.
    var runId: String?

    var id: String { name }
    var isStale: Bool { status == .running && heartbeatAgeSeconds >= 90 }
}

struct Ship: Identifiable, Codable, Equatable {
    let id: String
    var repo: String
    var prNumber: Int
    var branch: String
    var worktree: String
    var headSha: String = ""
    var targets: [Target] = []
    var autoMerge: Bool = false
    var dismissed: Bool = false
    var startedAt: Date = Date()

    var overallStatus: TargetStatus {
        let statuses = targets.map(\.status)
        // Empty target list = just-dispatched ship that hasn't laid down
        // runs yet. Don't let vacuous-truth allSatisfy claim "green".
        if statuses.isEmpty { return .pending }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.running) { return .running }
        if statuses.allSatisfy({ $0 == .passed || $0 == .skipped || $0 == .reused }) {
            return .passed
        }
        return .pending
    }
}

// MARK: - Badge

enum OverallBadge {
    case idle, running, allGreen, failed

    var symbol: String? {
        switch self {
        case .idle: return nil
        case .running: return "\u{25CF}"
        case .allGreen: return "\u{2713}"
        case .failed: return "\u{2717}"
        }
    }
}

extension Array where Element == Ship {
    var overallBadge: OverallBadge {
        let statuses = map(\.overallStatus)
        if statuses.contains(.failed) { return .failed }
        if statuses.isEmpty { return .idle }
        if statuses.allSatisfy({ $0 == .passed }) { return .allGreen }
        if statuses.contains(.running) { return .running }
        return .idle
    }
}
