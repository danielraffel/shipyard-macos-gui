import Foundation

/// One GitHub Actions workflow run. Parsed from `gh run list --json …`.
struct GitHubRun: Identifiable, Equatable {
    let id: Int64
    let repo: String
    let workflowName: String
    let headBranch: String
    let headSha: String
    let status: String            // queued | in_progress | completed
    let conclusion: String?       // success | failure | cancelled | skipped | neutral | timed_out | nil while running
    let url: URL?
    let createdAt: Date
    let updatedAt: Date

    var isTerminal: Bool { status == "completed" }
    var isFailure: Bool {
        guard let c = conclusion else { return false }
        return c == "failure" || c == "timed_out" || c == "cancelled"
    }
    var isRunning: Bool { status == "in_progress" || status == "queued" }

    /// Raw dotted signature used to de-dup against a ship. If a ship card
    /// already shows a run for (repo, headSha, workflowName), skip the
    /// row from the GitHub section.
    var dedupKey: String { "\(repo)\t\(headSha)\t\(workflowName.lowercased())" }
}

/// A single job within a run. `labels` carries the runner infra — e.g.
/// ["ubuntu-latest"] for GitHub-hosted, or ["self-hosted", "namespace",
/// "linux-x64"] for a Namespace runner. We derive a human-readable
/// provider from these labels.
struct GitHubJob: Decodable, Equatable, Hashable {
    let name: String
    let status: String
    let conclusion: String?
    let labels: [String]?
    let runnerName: String?

    /// Best-effort classification of which infrastructure this job
    /// ran on. Uses the labels array; falls back to runner name.
    var provider: String {
        let l = (labels ?? []).map { $0.lowercased() }
        if l.contains("namespace") || l.contains(where: { $0.contains("nsc") }) {
            return "namespace"
        }
        if l.contains("self-hosted") {
            return "self-hosted"
        }
        if l.contains(where: { $0.contains("ubuntu") || $0.contains("macos") || $0.contains("windows") }) {
            return "github-hosted"
        }
        if let r = runnerName?.lowercased() {
            if r.contains("namespace") { return "namespace" }
            if r.contains("nsc") { return "namespace" }
        }
        return l.first ?? "unknown"
    }

    /// The specific runner label — e.g. "ubuntu-latest" or
    /// "namespace-linux-arm64". Useful as a tooltip.
    var runnerLabel: String {
        (labels ?? []).last ?? runnerName ?? "?"
    }
}

