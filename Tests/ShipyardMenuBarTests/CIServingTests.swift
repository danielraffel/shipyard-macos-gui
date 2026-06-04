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
        // Honest wording: a running VM may be a warm runner waiting for a job,
        // so we report "N VM(s) up", not the over-stated "building (N)".
        XCTAssertEqual(CIServingStatus(installed: true, serving: true, busyVMs: 1).summary,
                       "Serving · 1 VM up")
        XCTAssertEqual(CIServingStatus(installed: true, serving: true, busyVMs: 2).summary,
                       "Serving · 2 VMs up")
        var toggling = CIServingStatus(installed: true, serving: true, busyVMs: 0)
        toggling.isToggling = true
        XCTAssertEqual(toggling.summary, "Updating…")
    }

    func testRunnerHeaderStateSeparatesFromConnection() {
        // No lane installed → header runner indicator is hidden entirely.
        let none = RunnerHeaderState.from([
            CIServingStatus(installed: false, serving: false, busyVMs: 0),
        ])
        XCTAssertEqual(none.kind, .none)
        XCTAssertFalse(none.isVisible)
        XCTAssertEqual(none.label, "")

        // Installed but not serving → "runner off".
        let off = RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: false, busyVMs: 0),
        ])
        XCTAssertEqual(off.kind, .off)
        XCTAssertTrue(off.isVisible)
        XCTAssertEqual(off.label, "runner off")

        // Serving, no VM up → "serving".
        let idle = RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: true, busyVMs: 0),
        ])
        XCTAssertEqual(idle.kind, .serving)
        XCTAssertEqual(idle.label, "serving")

        // Serving with a VM up → "serving · N up".
        let busy = RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: true, busyVMs: 1),
        ])
        XCTAssertEqual(busy.label, "serving · 1 up")
    }

    func testRunnerHeaderStateShowsUpdatingDuringToggle() {
        // A toggle in flight must read "updating…" in the header, not "runner
        // off" (installed + isToggling, serving not yet settled).
        var toggling = CIServingStatus(installed: true, serving: false, busyVMs: 0)
        toggling.isToggling = true
        let state = RunnerHeaderState.from([toggling])
        XCTAssertEqual(state.kind, .updating)
        XCTAssertEqual(state.label, "updating…")
        XCTAssertTrue(state.isVisible)
    }

    func testTartHomeHonorsEnvThenFallsBackToHomeVMs() {
        // The env branch is the fix for the VM-count-reads-0 bug on hosts whose
        // VMs live outside ~/VMs (e.g. a Mac Studio on /Volumes/Workshop/VMs).
        setenv("TART_HOME", "/Volumes/Workshop/VMs", 1)
        XCTAssertEqual(CIServingService.tartHome(), "/Volumes/Workshop/VMs")
        unsetenv("TART_HOME")
        XCTAssertTrue(CIServingService.tartHome().hasSuffix("/VMs"))
        XCTAssertFalse(CIServingService.tartHome().hasPrefix("/Volumes/Workshop"))
    }

    func testRunnerHeaderStateDoesNotDoubleCountHostGlobalVMCount() {
        // busyVMs is host-global (same number reported by every Tart-backed
        // lane), so the roll-up must take the max, not the sum.
        let state = RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: true, busyVMs: 1),  // macOS
            CIServingStatus(installed: true, serving: true, busyVMs: 1),  // linux (same VM count)
        ])
        XCTAssertEqual(state.runningVMs, 1)
        XCTAssertEqual(state.label, "serving · 1 up")
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
