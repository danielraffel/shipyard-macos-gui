import XCTest
@testable import Shipyard

/// Exercises the GUI-side parser for daemon NDJSON output. The daemon
/// (in the shipyard CLI) sends pre-decoded events with snake_case
/// fields; this test pins the mapping from those wire payloads to the
/// Swift `WebhookEvent` enum so a wire-format drift can't silently
/// break the macOS app's platform-dot rollup or merged-pill logic.
final class DaemonWireDecoderTests: XCTestCase {

    func test_workflowRun_decodesAllFields() {
        let obj: [String: Any] = [
            "kind": "workflow_run",
            "payload": [
                "action": "completed",
                "run_id": 42,
                "repo": "org/repo",
                "head_branch": "feature/x",
                "head_sha": "abc",
                "status": "completed",
                "conclusion": "success",
                "workflow_name": "CI",
                "html_url": "https://github.com/org/repo/actions/runs/42",
            ],
        ]
        guard case .workflowRun(let p) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected workflowRun")
            return
        }
        XCTAssertEqual(p.runId, 42)
        XCTAssertEqual(p.action, "completed")
        XCTAssertEqual(p.repo, "org/repo")
        XCTAssertEqual(p.headBranch, "feature/x")
        XCTAssertEqual(p.conclusion, "success")
        XCTAssertEqual(p.workflowName, "CI")
    }

    func test_workflowJob_decodesMatrixLabels() {
        let obj: [String: Any] = [
            "kind": "workflow_job",
            "payload": [
                "action": "in_progress",
                "run_id": 100,
                "job_id": 999,
                "repo": "org/repo",
                "name": "macOS (arm64)",
                "status": "in_progress",
                "conclusion": NSNull(),
                "runner_name": "macOS-arm64-1",
                "labels": ["self-hosted", "macOS"],
            ],
        ]
        guard case .workflowJob(let p) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected workflowJob")
            return
        }
        XCTAssertEqual(p.jobId, 999)
        XCTAssertEqual(p.runId, 100)
        XCTAssertEqual(p.status, "in_progress")
        XCTAssertNil(p.conclusion)
        XCTAssertEqual(p.labels, ["self-hosted", "macOS"])
    }

    func test_pullRequest_decodesMergedState() {
        let obj: [String: Any] = [
            "kind": "pull_request",
            "payload": [
                "action": "closed",
                "number": 581,
                "repo": "org/repo",
                "state": "closed",
                "merged": true,
                "merged_at": "2026-04-20T12:00:00Z",
                "closed_at": "2026-04-20T12:00:00Z",
            ],
        ]
        guard case .pullRequest(let p) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected pullRequest")
            return
        }
        XCTAssertEqual(p.number, 581)
        XCTAssertEqual(p.state, "closed")
        XCTAssertTrue(p.merged)
    }

    func test_unhandledKindFallsThrough() {
        let obj: [String: Any] = [
            "kind": "unhandled",
            "type": "star",
        ]
        guard case .unhandled(let type) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected unhandled")
            return
        }
        XCTAssertEqual(type, "star")
    }

    func test_unknownKindReturnsNil() {
        XCTAssertNil(DaemonWireDecoder.decodeEvent([
            "kind": "not-a-real-event",
            "payload": [:],
        ]))
    }

    func test_statusDecodesTunnelFields() {
        let obj: [String: Any] = [
            "type": "status",
            "tunnel": [
                "backend": "tailscale",
                "url": "https://foo.ts.net",
                "verified_at": NSNull(),
            ],
            "subscribers": 3,
            "last_event_at": NSNull(),
            "registered_repos": ["org/repo"],
        ]
        let status = DaemonWireDecoder.decodeStatus(obj)
        XCTAssertEqual(status.tunnelBackend, "tailscale")
        XCTAssertEqual(status.tunnelURL?.absoluteString, "https://foo.ts.net")
        XCTAssertEqual(status.subscribers, 3)
        XCTAssertEqual(status.registeredRepos, ["org/repo"])
    }

    func test_decideHonorsAutoModeWithoutTailscale() {
        let notInstalled = TailscaleStatus(
            binaryPath: nil,
            backendState: nil,
            dnsName: nil,
            funnelPermitted: false
        )
        let d = DaemonClient.decide(mode: .auto, tailscale: notInstalled)
        XCTAssertFalse(d.attemptLive)
        XCTAssertEqual(d.reason, .tailscaleNotInstalled)
    }

    func test_decideRefusesToAttemptWhenOff() {
        let ready = TailscaleStatus(
            binaryPath: "/opt/homebrew/bin/tailscale",
            backendState: "Running",
            dnsName: "foo.ts.net",
            funnelPermitted: true
        )
        let d = DaemonClient.decide(mode: .off, tailscale: ready)
        XCTAssertFalse(d.attemptLive)
        XCTAssertEqual(d.reason, .userDisabled)
    }
}
