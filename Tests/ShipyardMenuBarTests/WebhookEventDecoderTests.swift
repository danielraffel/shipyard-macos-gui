import XCTest
@testable import Shipyard

final class WebhookEventDecoderTests: XCTestCase {

    func test_decode_workflowRun_completed() {
        let json = """
        {
          "action": "completed",
          "workflow_run": {
            "id": 42,
            "head_branch": "feature/x",
            "head_sha": "abc",
            "status": "completed",
            "conclusion": "success",
            "name": "CI",
            "html_url": "https://github.com/org/repo/actions/runs/42"
          },
          "repository": { "full_name": "org/repo" }
        }
        """.data(using: .utf8)!
        guard case .workflowRun(let p) = WebhookEventDecoder.decode(
            eventHeader: "workflow_run", body: json
        ) else {
            XCTFail("expected workflowRun")
            return
        }
        XCTAssertEqual(p.action, "completed")
        XCTAssertEqual(p.runId, 42)
        XCTAssertEqual(p.repo, "org/repo")
        XCTAssertEqual(p.headBranch, "feature/x")
        XCTAssertEqual(p.conclusion, "success")
    }

    func test_decode_workflowJob_inProgress() {
        let json = """
        {
          "action": "in_progress",
          "workflow_job": {
            "id": 99,
            "run_id": 42,
            "name": "macOS (arm64)",
            "status": "in_progress",
            "conclusion": null,
            "runner_name": "macOS-arm64-1",
            "labels": ["self-hosted", "macOS"]
          },
          "repository": { "full_name": "org/repo" }
        }
        """.data(using: .utf8)!
        guard case .workflowJob(let p) = WebhookEventDecoder.decode(
            eventHeader: "workflow_job", body: json
        ) else {
            XCTFail("expected workflowJob")
            return
        }
        XCTAssertEqual(p.jobId, 99)
        XCTAssertEqual(p.runId, 42)
        XCTAssertEqual(p.name, "macOS (arm64)")
        XCTAssertEqual(p.status, "in_progress")
        XCTAssertNil(p.conclusion)
        XCTAssertEqual(p.labels, ["self-hosted", "macOS"])
    }

    func test_decode_pullRequest_merged() {
        let json = """
        {
          "action": "closed",
          "number": 581,
          "pull_request": {
            "number": 581,
            "state": "closed",
            "merged": true,
            "merged_at": "2026-04-20T12:00:00Z",
            "closed_at": "2026-04-20T12:00:00Z"
          },
          "repository": { "full_name": "org/repo" }
        }
        """.data(using: .utf8)!
        guard case .pullRequest(let p) = WebhookEventDecoder.decode(
            eventHeader: "pull_request", body: json
        ) else {
            XCTFail("expected pullRequest")
            return
        }
        XCTAssertEqual(p.number, 581)
        XCTAssertEqual(p.state, "closed")
        XCTAssertTrue(p.merged)
    }

    func test_decode_unknownEventType_isUnhandled() {
        let body = Data("{}".utf8)
        let result = WebhookEventDecoder.decode(eventHeader: "star", body: body)
        XCTAssertEqual(result, .unhandled(type: "star"))
    }

    func test_decode_missingEventHeader_returnsNil() {
        let body = Data("{}".utf8)
        XCTAssertNil(WebhookEventDecoder.decode(eventHeader: nil, body: body))
        XCTAssertNil(WebhookEventDecoder.decode(eventHeader: "", body: body))
    }

    func test_decode_malformedBody_returnsNil() {
        let body = Data("{oops".utf8)
        XCTAssertNil(WebhookEventDecoder.decode(
            eventHeader: "workflow_run", body: body
        ))
    }

    func test_decode_workflowRun_missingRepository_returnsNil() {
        let json = """
        {
          "action": "completed",
          "workflow_run": { "id": 1, "head_branch": "x", "head_sha": "y", "status": "completed" }
        }
        """.data(using: .utf8)!
        XCTAssertNil(WebhookEventDecoder.decode(
            eventHeader: "workflow_run", body: json
        ))
    }
}
