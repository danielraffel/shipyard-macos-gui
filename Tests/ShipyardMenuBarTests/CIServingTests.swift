import XCTest
@testable import Shipyard

final class CIServingTests: XCTestCase {
    func testParsesRunningCountFromRunningBool() {
        let json = """
        [{"Name":"ephr-1","Running":true,"State":"running"},
         {"Name":"golden","Running":false,"State":"stopped"}]
        """
        XCTAssertEqual(CIServingService.parseRunningVMCount(json), 1)
    }

    func testParsesRunningCountFromStateStringOnly() {
        let json = #"[{"Name":"a","State":"running"},{"Name":"b","State":"stopped"}]"#
        XCTAssertEqual(CIServingService.parseRunningVMCount(json), 1)
    }

    func testCountsMultipleRunning() {
        let json = #"[{"Running":true},{"Running":true},{"Running":false}]"#
        XCTAssertEqual(CIServingService.parseRunningVMCount(json), 2)
    }

    func testEmptyAndMalformedAreZero() {
        XCTAssertEqual(CIServingService.parseRunningVMCount("[]"), 0)
        XCTAssertEqual(CIServingService.parseRunningVMCount(""), 0)
        XCTAssertEqual(CIServingService.parseRunningVMCount("not json"), 0)
    }

    func testStatusSummary() {
        XCTAssertEqual(CIServingStatus(installed: false, serving: false, busyVMs: 0).summary,
                       "Not set up on this Mac")
        XCTAssertEqual(CIServingStatus(installed: true, serving: false, busyVMs: 0).summary,
                       "Not serving")
        XCTAssertEqual(CIServingStatus(installed: true, serving: true, busyVMs: 0).summary,
                       "Serving · idle")
        XCTAssertEqual(CIServingStatus(installed: true, serving: true, busyVMs: 2).summary,
                       "Serving · building (2)")
        var toggling = CIServingStatus(installed: true, serving: true, busyVMs: 0)
        toggling.isToggling = true
        XCTAssertEqual(toggling.summary, "Updating…")
    }

    func testKnownLanesAreMacOSLinuxWindows() {
        let lanes = CIServingLane.known
        XCTAssertEqual(lanes.map(\.id), ["macos", "linux", "windows"])

        let mac = lanes[0]
        XCTAssertEqual(mac.platform, "macOS")
        XCTAssertTrue(mac.plistPath.hasSuffix(
            "Library/LaunchAgents/com.danielraffel.pulp.tart-runner.plist"))

        let linux = lanes[1]
        XCTAssertEqual(linux.platform, "Linux")
        XCTAssertEqual(linux.agentLabel, "com.danielraffel.pulp.tart-runner-linux")
        XCTAssertTrue(linux.plistPath.hasSuffix(
            "Library/LaunchAgents/com.danielraffel.pulp.tart-runner-linux.plist"))

        let windows = lanes[2]
        XCTAssertEqual(windows.platform, "Windows")
        XCTAssertEqual(windows.agentLabel, "com.danielraffel.pulp.qemu-runner-windows")
        XCTAssertTrue(windows.plistPath.hasSuffix(
            "Library/LaunchAgents/com.danielraffel.pulp.qemu-runner-windows.plist"))

        // Every lane's plist path is derived from its agent label (universal shape).
        for lane in lanes {
            XCTAssertTrue(lane.plistPath.hasSuffix("Library/LaunchAgents/\(lane.agentLabel).plist"))
        }
    }
}
