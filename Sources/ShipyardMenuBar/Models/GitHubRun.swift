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
