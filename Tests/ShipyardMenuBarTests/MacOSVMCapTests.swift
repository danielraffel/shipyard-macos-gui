import XCTest
@testable import Shipyard

final class MacOSVMCapTests: XCTestCase {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "macos-vm-cap-\(UUID().uuidString)/cap"
    }

    func testClampStaysInOneToTwo() {
        XCTAssertEqual(MacOSVMCap.clamp(0), 1)
        XCTAssertEqual(MacOSVMCap.clamp(1), 1)
        XCTAssertEqual(MacOSVMCap.clamp(2), 2)
        XCTAssertEqual(MacOSVMCap.clamp(5), 2)
        XCTAssertEqual(MacOSVMCap.clamp(-3), 1)
    }

    func testReadMissingFileIsDefault() {
        XCTAssertEqual(MacOSVMCap.read(path: "/no/such/macos-vm-cap"), MacOSVMCap.defaultCap)
    }

    func testReadValidValues() throws {
        let p = tmpPath()
        XCTAssertTrue(MacOSVMCap.write(1, path: p))
        XCTAssertEqual(MacOSVMCap.read(path: p), 1)
        XCTAssertTrue(MacOSVMCap.write(2, path: p))
        XCTAssertEqual(MacOSVMCap.read(path: p), 2)
        try? FileManager.default.removeItem(atPath: (p as NSString).deletingLastPathComponent)
    }

    func testReadGarbageAndOutOfRangeFallBackOrClamp() throws {
        let p = tmpPath()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // garbage → default
        try "abc\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(MacOSVMCap.read(path: p), MacOSVMCap.defaultCap)
        // 0 is below min → default (mirrors the runner's `>= 1` guard)
        try "0\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(MacOSVMCap.read(path: p), MacOSVMCap.defaultCap)
        // a too-large value is clamped down, not rejected
        try "9\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(MacOSVMCap.read(path: p), 2)
        // leading digits + trailing junk still parse
        try "1 # while working\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(MacOSVMCap.read(path: p), 1)
    }

    func testReadTwoDigitClampsToTwo() throws {
        let p = tmpPath()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // The GUI never writes this, but if the file said "12" the GUI shows the
        // safe clamped 2 (it does NOT surface a 12-VM cap).
        try "12\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(MacOSVMCap.read(path: p), 2)
    }

    func testWriteToUnwritablePathReturnsFalse() {
        // A path under a non-directory parent can't be created/written → false,
        // which setMacOSVMCap relies on to avoid lying about the enforced cap.
        XCTAssertFalse(MacOSVMCap.write(1, path: "/dev/null/nope/cap"))
    }

    func testWriteClampsAndRoundTrips() {
        let p = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: (p as NSString).deletingLastPathComponent) }
        MacOSVMCap.write(99, path: p)
        XCTAssertEqual(MacOSVMCap.read(path: p), 2)
        MacOSVMCap.write(0, path: p)
        XCTAssertEqual(MacOSVMCap.read(path: p), 1)
        // trailing newline matches the shell-side writer
        let raw = try? String(contentsOfFile: p, encoding: .utf8)
        XCTAssertEqual(raw, "1\n")
    }
}
