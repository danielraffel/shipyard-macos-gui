import XCTest
@testable import Shipyard

final class CIPoolTests: XCTestCase {
    // MARK: - Parse `tartci pool status --json` participation

    func testParseParticipatingTrueFromStatusJSON() throws {
        // The real `tartci pool status --json` shape:
        // {"host":.., "participating":bool, "runners":[{"label":.., "loaded":bool}]}.
        let json = """
        {
          "host": "BlackBook-Pro.local",
          "participating": true,
          "runners": [
            {"label": "com.danielraffel.pulp.tart-runner-macos-gate", "loaded": true},
            {"label": "actions.runner.danielraffel-pulp.pulp-build-m5", "loaded": true}
          ]
        }
        """
        XCTAssertEqual(CIPool.parseParticipating(json), true)
    }

    func testParseParticipatingFalseFromStatusJSON() throws {
        let json = """
        {
          "host": "BlackBook-Pro.local",
          "participating": false,
          "runners": [
            {"label": "com.danielraffel.pulp.tart-runner-macos-gate", "loaded": false}
          ]
        }
        """
        XCTAssertEqual(CIPool.parseParticipating(json), false)
    }

    func testParseParticipatingTolerantOfNonBoolEncodings() {
        // Some CLIs stringify or integer-encode booleans.
        XCTAssertEqual(CIPool.parseParticipating(#"{"participating": 1}"#), true)
        XCTAssertEqual(CIPool.parseParticipating(#"{"participating": 0}"#), false)
        XCTAssertEqual(CIPool.parseParticipating(#"{"participating": "true"}"#), true)
        XCTAssertEqual(CIPool.parseParticipating(#"{"participating": "false"}"#), false)
    }

    // MARK: - Reject non-status / invalid bodies (so callers fall back to the file)

    func testParseParticipatingRejectsMissingAndInvalid() {
        XCTAssertNil(CIPool.parseParticipating(""))
        XCTAssertNil(CIPool.parseParticipating("not json"))
        XCTAssertNil(CIPool.parseParticipating("[]"))                 // array, not an object
        XCTAssertNil(CIPool.parseParticipating(#"{"host": "x"}"#))    // no participating field
        XCTAssertNil(CIPool.parseParticipating(#"{"participating": "maybe"}"#))
    }

    // MARK: - Absent-tartci resolution (injected empty filesystem)

    func testResolveTartciReturnsNilWhenAbsent() {
        // No candidate exists → nil, which drives the per-lane launchctl fallback
        // in `setAllServing` and the on-disk-file fallback in `readParticipating`.
        // A FileManager that reports nothing executable stands in for a host
        // without tartci, without touching the real one that may be installed.
        final class NoExecFileManager: FileManager {
            override func isExecutableFile(atPath path: String) -> Bool { false }
        }
        XCTAssertNil(CIPool.resolveTartci(fileManager: NoExecFileManager()))
    }
}
