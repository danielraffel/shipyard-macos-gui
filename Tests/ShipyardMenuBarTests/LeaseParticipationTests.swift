import XCTest
@testable import Shipyard

final class LeaseParticipationTests: XCTestCase {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "native-build-participation-\(UUID().uuidString)/flag"
    }

    private func write(_ contents: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testMissingFileDefaultsToParticipating() {
        // A freshly-onboarded host with no flag file is in the pool by default.
        XCTAssertTrue(LeaseParticipation.read(path: "/no/such/native-build-participation"))
        XCTAssertTrue(LeaseParticipation.defaultParticipating)
    }

    func testReadZeroIsOptedOut() throws {
        // The GUI no longer writes this file (tartci pool owns it); read still
        // interprets the shell-written `0\n` / `1\n` form as opt-out / opt-in.
        let p = tmpPath()
        let dir = (p as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write("0\n", to: p)
        XCTAssertFalse(LeaseParticipation.read(path: p))
        try write("1\n", to: p)
        XCTAssertTrue(LeaseParticipation.read(path: p))
    }

    func testReadGarbageAndZeroSemantics() throws {
        let p = tmpPath()
        let dir = (p as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Leading digit governs; trailing junk is ignored.
        try write("1 # participating\n", to: p)
        XCTAssertTrue(LeaseParticipation.read(path: p))
        try write("0\n", to: p)
        XCTAssertFalse(LeaseParticipation.read(path: p))
        // Any nonzero leading number ⇒ participating.
        try write("2\n", to: p)
        XCTAssertTrue(LeaseParticipation.read(path: p))
        // Non-numeric garbage ⇒ the default (participating), never a false opt-out.
        try write("yes\n", to: p)
        XCTAssertTrue(LeaseParticipation.read(path: p))
    }
}
