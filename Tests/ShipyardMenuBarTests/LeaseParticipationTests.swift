import XCTest
@testable import Shipyard

final class LeaseParticipationTests: XCTestCase {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "native-build-participation-\(UUID().uuidString)/flag"
    }

    func testMissingFileDefaultsToParticipating() {
        // A freshly-onboarded host with no flag file is in the pool by default.
        XCTAssertTrue(LeaseParticipation.read(path: "/no/such/native-build-participation"))
        XCTAssertTrue(LeaseParticipation.defaultParticipating)
    }

    func testWriteReadRoundTrip() {
        let p = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: (p as NSString).deletingLastPathComponent) }
        XCTAssertTrue(LeaseParticipation.write(false, path: p))
        XCTAssertFalse(LeaseParticipation.read(path: p))
        XCTAssertTrue(LeaseParticipation.write(true, path: p))
        XCTAssertTrue(LeaseParticipation.read(path: p))
    }

    func testWriteFormatMatchesShellWriters() throws {
        let p = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: (p as NSString).deletingLastPathComponent) }
        LeaseParticipation.write(false, path: p)
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), "0\n")
        LeaseParticipation.write(true, path: p)
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), "1\n")
    }

    func testReadGarbageAndZeroSemantics() throws {
        let p = tmpPath()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Leading digit governs; trailing junk is ignored.
        try "1 # participating\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertTrue(LeaseParticipation.read(path: p))
        try "0\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertFalse(LeaseParticipation.read(path: p))
        // Any nonzero leading number ⇒ participating.
        try "2\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertTrue(LeaseParticipation.read(path: p))
        // Non-numeric garbage ⇒ the default (participating), never a false opt-out.
        try "yes\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertTrue(LeaseParticipation.read(path: p))
    }

    func testWriteToUnwritablePathReturnsFalse() {
        // A path under a non-directory parent can't be written → false, so the
        // caller won't claim an opt-out state that never reached disk.
        XCTAssertFalse(LeaseParticipation.write(false, path: "/dev/null/nope/flag"))
    }

    // MARK: - Host-wide aggregate rule (per-lane toggle → host flag)

    func testHostParticipatingAggregateRule() {
        // Turning any lane ON ⇒ participating, regardless of others.
        XCTAssertTrue(LeaseParticipation.hostParticipating(togglingOn: true, otherLanesServing: false))
        XCTAssertTrue(LeaseParticipation.hostParticipating(togglingOn: true, otherLanesServing: true))
        // Turning a lane OFF opts out ONLY when no other lane is still serving.
        XCTAssertTrue(LeaseParticipation.hostParticipating(togglingOn: false, otherLanesServing: true))
        XCTAssertFalse(LeaseParticipation.hostParticipating(togglingOn: false, otherLanesServing: false))
    }
}
