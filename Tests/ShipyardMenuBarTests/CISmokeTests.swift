import XCTest
@testable import Shipyard

final class CISmokeTests: XCTestCase {
    func testKnownLanesAreOnlyWiredEmulationPaths() {
        let lanes = CISmokeLane.known
        // Linux/qemu-user is the only wired emulation path today. Windows/Prism
        // is intentionally absent so the UI never offers a no-op.
        XCTAssertEqual(lanes.map(\.id), ["linux-x64"])
        let linux = lanes[0]
        XCTAssertEqual(linux.os, "linux")
        XCTAssertEqual(linux.targetArch, "x86_64")
        XCTAssertEqual(linux.title, "Linux x86_64 (emulated)")
    }

    func testCommandArgvShape() {
        let lane = CISmokeLane(id: "linux-x64", title: "Linux x86_64 (emulated)",
                               os: "linux", targetArch: "x86_64")
        XCTAssertEqual(lane.commandArgs, ["up", "linux", "--target-arch", "x86_64"])
        XCTAssertEqual(lane.selfTestArgs,
                       ["up", "linux", "--target-arch", "x86_64", "--self-test"])
    }

    func testTerminalMapsExitCodeToState() {
        XCTAssertEqual(
            CISmokeStatus.terminal(exitCode: 0, outputTail: "x\n✓ verified").state, .passed)
        XCTAssertEqual(
            CISmokeStatus.terminal(exitCode: 1, outputTail: "x\n✗ no compiler").state, .failed)
    }

    func testTerminalKeepsLastLineAsDetail() {
        let s = CISmokeStatus.terminal(
            exitCode: 0, outputTail: "cloning…\nbuilding…\n✓ x86_64 cross-compile verified\n")
        XCTAssertEqual(s.detail, "✓ x86_64 cross-compile verified")
        XCTAssertTrue(s.summary.hasPrefix("Passed · "))
    }

    func testTerminalTruncatesLongDetail() {
        let long = String(repeating: "z", count: 400)
        let s = CISmokeStatus.terminal(exitCode: 1, outputTail: long)
        XCTAssertEqual(s.detail?.count, 120)
        XCTAssertEqual(s.state, .failed)
    }

    func testStatusSummaries() {
        XCTAssertTrue(CISmokeStatus.unavailable.summary.contains("tartci not found"))
        XCTAssertTrue(CISmokeStatus.idle.summary.hasPrefix("Ready"))
        XCTAssertEqual(CISmokeStatus(state: .running, detail: nil).summary,
                       "Running… (cross-compile + emulated tests, a few minutes)")
        XCTAssertEqual(CISmokeStatus(state: .passed, detail: nil).summary, "Passed")
        XCTAssertEqual(CISmokeStatus(state: .failed, detail: nil).summary, "Failed")
    }

    func testCanRunGating() {
        XCTAssertFalse(CISmokeStatus.unavailable.canRun)   // no tartci → can't run
        XCTAssertFalse(CISmokeStatus(state: .running, detail: nil).canRun)  // already running
        XCTAssertTrue(CISmokeStatus.idle.canRun)
        XCTAssertTrue(CISmokeStatus(state: .passed, detail: nil).canRun)    // re-runnable
        XCTAssertTrue(CISmokeStatus(state: .failed, detail: nil).canRun)
    }

    func testResolveTartciFindsAnExplicitCandidate() {
        // A smoke lane is unavailable when tartci can't be found; the resolver
        // honors explicit candidate paths (used by TARTCI_BIN / known locations).
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "tartci-test-\(UUID().uuidString)"
        fm.createFile(atPath: tmp, contents: Data("#!/bin/sh\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(atPath: tmp) }
        XCTAssertEqual(
            ShipyardProcessEnvironment.findExecutable(named: "tartci", candidates: [tmp]), tmp)
    }
}
