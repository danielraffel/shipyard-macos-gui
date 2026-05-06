import XCTest
@testable import Shipyard

final class PRStatePollerTests: XCTestCase {
    func test_apiPathUsesRESTPullEndpoint() {
        XCTAssertEqual(
            PRStatePoller.apiPath(repo: "owner/repo", pr: 581),
            "repos/owner/repo/pulls/581"
        )
        XCTAssertNil(PRStatePoller.apiPath(repo: "not-a-repo", pr: 581))
        XCTAssertNil(PRStatePoller.apiPath(repo: "owner/repo", pr: 0))
    }

    func test_decodeRESTPayloadMapsMergedPullRequest() {
        let state = PRStatePoller.decodeRESTPayload("""
        {
          "state": "closed",
          "merged_at": "2026-05-06T12:00:00Z",
          "closed_at": "2026-05-06T12:00:00Z"
        }
        """)

        XCTAssertEqual(state?.state, "MERGED")
        XCTAssertEqual(state?.isMerged, true)
        XCTAssertNotNil(state?.mergedAt)
        XCTAssertNotNil(state?.closedAt)
    }

    func test_decodeRESTPayloadMapsOpenPullRequest() {
        let state = PRStatePoller.decodeRESTPayload("""
        {
          "state": "open",
          "merged_at": null,
          "closed_at": null
        }
        """)

        XCTAssertEqual(state?.state, "OPEN")
        XCTAssertEqual(state?.isMerged, false)
        XCTAssertEqual(state?.isClosed, false)
    }
}
