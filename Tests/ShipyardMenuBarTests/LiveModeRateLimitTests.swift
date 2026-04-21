import XCTest
@testable import Shipyard

/// Regression guards for the "webhooks blew our GitHub rate limit"
/// class of bug. The root failure was `apply(webhookEvent:)` calling
/// `fetchRunsForShipOnDemand(force: true)` on every workflow_run /
/// workflow_job / pull_request event — defeating the whole point of
/// webhooks (which should *replace* polling).
///
/// These tests pin the contract: a webhook delivery must mutate only
/// in-memory caches, never trigger a subprocess. We can't easily
/// observe "no `gh api` invocation" from here (Process isn't mocked),
/// so we verify the observable side-effect: after apply(), the cached
/// state reflects the webhook payload *directly*, proving we read it
/// from the payload rather than re-fetching.
@MainActor
final class LiveModeRateLimitTests: XCTestCase {

    // MARK: - workflow_run: status + conclusion patched in place

    func test_workflowRun_patchesCachedRunStatusAndConclusion() {
        let store = AppStore()
        let repo = "org/repo"
        let branch = "feature/x"
        let runId: Int64 = 42

        // Seed: one run cached in both repo-wide + branch-scoped maps.
        let seed = GitHubRun(
            id: runId, repo: repo, workflowName: "CI",
            headBranch: branch, headSha: "abc",
            status: "in_progress", conclusion: nil,
            url: nil,
            createdAt: Date(), updatedAt: Date()
        )
        store.githubRunsByRepo[repo] = [seed]
        store.githubRunsByBranch["\(repo)\t\(branch)"] = [seed]

        // Fire a completed webhook for the same run.
        store.apply(webhookEvent: .workflowRun(.init(
            action: "completed",
            runId: runId,
            repo: repo,
            headBranch: branch,
            headSha: "abc",
            status: "completed",
            conclusion: "failure",
            workflowName: "CI",
            htmlURL: nil
        )))

        // Both caches should now reflect the completed/failure state.
        XCTAssertEqual(store.githubRunsByRepo[repo]?.first?.status, "completed")
        XCTAssertEqual(store.githubRunsByRepo[repo]?.first?.conclusion, "failure")
        XCTAssertEqual(store.githubRunsByBranch["\(repo)\t\(branch)"]?.first?.status, "completed")
        XCTAssertEqual(store.githubRunsByBranch["\(repo)\t\(branch)"]?.first?.conclusion, "failure")
    }

    // MARK: - workflow_job: job status patched in place

    func test_workflowJob_patchesCachedJobStatusAndConclusion() {
        let store = AppStore()
        let runId: Int64 = 100
        let jobId: Int64 = 999
        let seed = GitHubJob(
            databaseId: jobId,
            name: "macOS (arm64)",
            status: "in_progress",
            conclusion: nil,
            labels: ["self-hosted", "macOS"],
            runnerName: "macOS-arm64-1"
        )
        store.jobsByRunId[runId] = [seed]

        store.apply(webhookEvent: .workflowJob(.init(
            action: "completed",
            runId: runId,
            jobId: jobId,
            repo: "org/repo",
            name: "macOS (arm64)",
            status: "completed",
            conclusion: "success",
            runnerName: "macOS-arm64-1",
            labels: ["self-hosted", "macOS"]
        )))

        let updated = store.jobsByRunId[runId]?.first
        XCTAssertEqual(updated?.status, "completed")
        XCTAssertEqual(updated?.conclusion, "success")
        XCTAssertEqual(updated?.databaseId, jobId,
                       "patch must preserve the original databaseId")
    }

    func test_workflowJob_unknownJobId_isNoOp() {
        // A workflow_job event for a run we haven't fetched yet
        // should NOT populate an empty jobs entry — that would make
        // isActivelyWorkedOn think the run exists when it doesn't,
        // and break the job rollup.
        let store = AppStore()
        store.apply(webhookEvent: .workflowJob(.init(
            action: "in_progress",
            runId: 12345,
            jobId: 67890,
            repo: "org/repo",
            name: "macOS",
            status: "in_progress",
            conclusion: nil,
            runnerName: nil,
            labels: []
        )))
        XCTAssertNil(store.jobsByRunId[12345])
    }

    // MARK: - pull_request: PR state built from payload

    func test_pullRequest_merged_buildsStateWithoutFetch() {
        let store = AppStore()
        let payload = WebhookEvent.PullRequestPayload(
            action: "closed",
            number: 581,
            repo: "org/repo",
            state: "closed",
            merged: true,
            mergedAt: "2026-04-20T12:00:00Z",
            closedAt: "2026-04-20T12:00:00Z"
        )
        store.apply(webhookEvent: .pullRequest(payload))

        let state = store.prStateByKey["org/repo\t581"]
        XCTAssertEqual(state?.state, "MERGED")
        XCTAssertEqual(state?.isMerged, true)
        XCTAssertNotNil(state?.mergedAt)
    }

    func test_pullRequest_openedEvent_setsOpenState() {
        let store = AppStore()
        store.apply(webhookEvent: .pullRequest(.init(
            action: "opened",
            number: 1,
            repo: "org/repo",
            state: "open",
            merged: false,
            mergedAt: nil,
            closedAt: nil
        )))
        let state = store.prStateByKey["org/repo\t1"]
        XCTAssertEqual(state?.state, "OPEN")
        XCTAssertEqual(state?.isMerged, false)
        XCTAssertEqual(state?.isClosed, false)
    }

    // MARK: - unhandled event types are a no-op

    func test_unhandledEvent_doesNotMutateCaches() {
        let store = AppStore()
        let runsBefore = store.githubRunsByRepo
        let jobsBefore = store.jobsByRunId
        let prsBefore = store.prStateByKey

        store.apply(webhookEvent: .unhandled(type: "star"))

        XCTAssertEqual(store.githubRunsByRepo, runsBefore)
        XCTAssertEqual(store.jobsByRunId, jobsBefore)
        XCTAssertEqual(store.prStateByKey, prsBefore)
    }
}
