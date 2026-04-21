import Foundation

/// Typed, normalized view of a GitHub webhook delivery.
///
/// We only decode the fields the app actually consumes — enough to
/// mutate the ship/run state in `AppStore`. Everything else is
/// ignored. Pure-data type makes decoding unit-testable.
enum WebhookEvent: Equatable {

    /// `workflow_run` event — whole-workflow state change.
    case workflowRun(WorkflowRunPayload)
    /// `workflow_job` event — a matrix-job state change. This is the
    /// one that moves the per-platform dots in the collapsed card.
    case workflowJob(WorkflowJobPayload)
    /// `pull_request` event — open/closed/merged transitions. Drives
    /// the merged/closed pill + removes ships from the list.
    case pullRequest(PullRequestPayload)
    /// Anything else we chose not to model. Callers typically ignore.
    case unhandled(type: String)

    struct WorkflowRunPayload: Equatable {
        let action: String           // requested / in_progress / completed
        let runId: Int64
        let repo: String             // "owner/name"
        let headBranch: String
        let headSha: String
        let status: String           // queued / in_progress / completed
        let conclusion: String?      // success / failure / cancelled / ...
        let workflowName: String
        let htmlURL: String?
    }

    struct WorkflowJobPayload: Equatable {
        let action: String           // queued / in_progress / completed
        let runId: Int64
        let jobId: Int64
        let repo: String
        let name: String
        let status: String
        let conclusion: String?
        let runnerName: String?
        let labels: [String]
    }

    struct PullRequestPayload: Equatable {
        let action: String           // opened / closed / reopened / ...
        let number: Int
        let repo: String
        let state: String            // open / closed
        let merged: Bool
        let mergedAt: String?
        let closedAt: String?
    }
}

/// Decode a raw webhook delivery into a `WebhookEvent`.
///
/// Caller provides the `X-GitHub-Event` header (the event type) and
/// the JSON body. Unknown event types come back as `.unhandled`.
enum WebhookEventDecoder {

    static func decode(eventHeader: String?, body: Data) -> WebhookEvent? {
        guard let type = eventHeader, !type.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        switch type {
        case "workflow_run":
            return decodeWorkflowRun(obj: obj)
        case "workflow_job":
            return decodeWorkflowJob(obj: obj)
        case "pull_request":
            return decodePullRequest(obj: obj)
        default:
            return .unhandled(type: type)
        }
    }

    private static func decodeWorkflowRun(obj: [String: Any]) -> WebhookEvent? {
        let action = obj["action"] as? String ?? ""
        guard let run = obj["workflow_run"] as? [String: Any] else { return nil }
        guard let repoName = (obj["repository"] as? [String: Any])?["full_name"] as? String,
              let runId = run["id"] as? Int64 ?? (run["id"] as? Int).map(Int64.init) else {
            return nil
        }
        return .workflowRun(.init(
            action: action,
            runId: runId,
            repo: repoName,
            headBranch: run["head_branch"] as? String ?? "",
            headSha: run["head_sha"] as? String ?? "",
            status: run["status"] as? String ?? "",
            conclusion: run["conclusion"] as? String,
            workflowName: run["name"] as? String ?? "",
            htmlURL: run["html_url"] as? String
        ))
    }

    private static func decodeWorkflowJob(obj: [String: Any]) -> WebhookEvent? {
        let action = obj["action"] as? String ?? ""
        guard let job = obj["workflow_job"] as? [String: Any] else { return nil }
        guard let repoName = (obj["repository"] as? [String: Any])?["full_name"] as? String,
              let jobId = job["id"] as? Int64 ?? (job["id"] as? Int).map(Int64.init),
              let runId = job["run_id"] as? Int64 ?? (job["run_id"] as? Int).map(Int64.init) else {
            return nil
        }
        return .workflowJob(.init(
            action: action,
            runId: runId,
            jobId: jobId,
            repo: repoName,
            name: job["name"] as? String ?? "",
            status: job["status"] as? String ?? "",
            conclusion: job["conclusion"] as? String,
            runnerName: job["runner_name"] as? String,
            labels: (job["labels"] as? [String]) ?? []
        ))
    }

    private static func decodePullRequest(obj: [String: Any]) -> WebhookEvent? {
        let action = obj["action"] as? String ?? ""
        guard let pr = obj["pull_request"] as? [String: Any] else { return nil }
        guard let repoName = (obj["repository"] as? [String: Any])?["full_name"] as? String,
              let number = pr["number"] as? Int else {
            return nil
        }
        return .pullRequest(.init(
            action: action,
            number: number,
            repo: repoName,
            state: pr["state"] as? String ?? "",
            merged: pr["merged"] as? Bool ?? false,
            mergedAt: pr["merged_at"] as? String,
            closedAt: pr["closed_at"] as? String
        ))
    }
}
