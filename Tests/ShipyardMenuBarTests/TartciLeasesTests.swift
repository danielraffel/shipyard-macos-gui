import XCTest
@testable import Shipyard

final class TartciLeasesTests: XCTestCase {
    // MARK: - Parse the nested {used,total} shape

    func testParseNestedCoresMemoryTierLeases() throws {
        let json = """
        {
          "tier": "native-build",
          "cores": {"used": 8, "total": 12},
          "memory_mb": {"used": 16384, "total": 32768},
          "leases": [
            {"id": "a", "cores": 4},
            {"id": "b", "cores": 4}
          ]
        }
        """
        let snap = try XCTUnwrap(TartciLeases.parse(json))
        XCTAssertEqual(snap.tier, "native-build")
        XCTAssertEqual(snap.usedCores, 8)
        XCTAssertEqual(snap.totalCores, 12)
        XCTAssertEqual(snap.usedMemoryMB, 16384)
        XCTAssertEqual(snap.totalMemoryMB, 32768)
        XCTAssertEqual(snap.heldLeases, 2)   // counted from the leases array
        XCTAssertEqual(snap.summary, "8/12 cores · 16384/32768 MB")
        XCTAssertEqual(snap.coreFraction, 8.0 / 12.0, accuracy: 0.0001)
    }

    // MARK: - Tolerant of flat aliases and stringified numbers

    func testParseFlatAliasesAndStringNumbers() throws {
        let json = """
        {
          "used_cores": "2",
          "total_cores": 10,
          "used_memory_mb": 4096,
          "total_memory_mb": "65536",
          "held_leases": 1
        }
        """
        let snap = try XCTUnwrap(TartciLeases.parse(json))
        XCTAssertNil(snap.tier)
        XCTAssertEqual(snap.usedCores, 2)
        XCTAssertEqual(snap.totalCores, 10)
        XCTAssertEqual(snap.usedMemoryMB, 4096)
        XCTAssertEqual(snap.totalMemoryMB, 65536)
        XCTAssertEqual(snap.heldLeases, 1)   // from held_leases (no leases array)
    }

    // MARK: - Reject non-lease / invalid bodies (so read() falls through)

    func testParseRejectsEmptyAndInvalid() {
        XCTAssertNil(TartciLeases.parse(""))
        XCTAssertNil(TartciLeases.parse("not json"))
        XCTAssertNil(TartciLeases.parse("[]"))          // array, not an object
        // A status body with none of the governor's fields is not a lease report.
        XCTAssertNil(TartciLeases.parse(#"{"version": "1.2.3", "vms": 2}"#))
    }

    func testParseTierOnlyIsAcceptedButShowsHeldSummary() throws {
        // Tier present but no core/mem budget yet → still a governor report; the
        // summary degrades to the held-count form rather than "0/0".
        let snap = try XCTUnwrap(TartciLeases.parse(#"{"tier": "idle"}"#))
        XCTAssertEqual(snap.tier, "idle")
        XCTAssertEqual(snap.totalCores, 0)
        XCTAssertEqual(snap.summary, "0 leases held")
        XCTAssertEqual(snap.coreFraction, 0)   // no divide-by-zero
    }

    func testSummaryOmitsUnreportedDimension() {
        let coresOnly = TartciLeaseSnapshot(
            tier: nil, usedCores: 3, totalCores: 8,
            usedMemoryMB: 0, totalMemoryMB: 0, heldLeases: 1)
        XCTAssertEqual(coresOnly.summary, "3/8 cores")
        let oneLease = TartciLeaseSnapshot(
            tier: nil, usedCores: 0, totalCores: 0,
            usedMemoryMB: 0, totalMemoryMB: 0, heldLeases: 1)
        XCTAssertEqual(oneLease.summary, "1 lease held")
    }

    // MARK: - State helper

    func testStateSnapshotAccessor() {
        let snap = TartciLeaseSnapshot(
            tier: "native-build", usedCores: 1, totalCores: 2,
            usedMemoryMB: 0, totalMemoryMB: 0, heldLeases: 0)
        XCTAssertEqual(TartciLeases.State.available(snap).snapshot, snap)
        XCTAssertNil(TartciLeases.State.notInstalled.snapshot)
        XCTAssertNil(TartciLeases.State.unavailable("x").snapshot)
    }

    // MARK: - Absent-governor resolution (injected empty filesystem)

    func testResolveTartciReturnsNilWhenAbsent() {
        // No candidate exists → nil (drives the "Governor not installed" panel).
        // A FileManager that reports nothing executable stands in for a host
        // without tartci, without touching the real one that may be installed.
        final class NoExecFileManager: FileManager {
            override func isExecutableFile(atPath path: String) -> Bool { false }
        }
        XCTAssertNil(TartciLeases.resolveTartci(fileManager: NoExecFileManager()))
    }
}
