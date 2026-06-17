import XCTest
@testable import Shipyard

final class CIServingTests: XCTestCase {
    // MARK: - Status summary (building vs waiting)

    func testStatusSummary() {
        XCTAssertEqual(CIServingStatus(installed: false, serving: false).summary,
                       "Not set up on this Mac")
        XCTAssertEqual(CIServingStatus(installed: true, serving: false).summary,
                       "Not serving")
        XCTAssertEqual(CIServingStatus(installed: true, serving: true).summary,
                       "Serving · idle")
        // A warm runner waiting for work is NOT "building".
        XCTAssertEqual(CIServingStatus(installed: true, serving: true, waiting: 1).summary,
                       "Waiting · 1 ready")
        // A busy runner IS building.
        XCTAssertEqual(CIServingStatus(installed: true, serving: true, building: 1).summary,
                       "Building 1 job")
        XCTAssertEqual(CIServingStatus(installed: true, serving: true, building: 2).summary,
                       "Building 2 jobs")
        // Building wins over waiting in the summary.
        XCTAssertEqual(CIServingStatus(installed: true, serving: true, building: 1, waiting: 2).summary,
                       "Building 1 job")
        var toggling = CIServingStatus(installed: true, serving: true)
        toggling.isToggling = true
        XCTAssertEqual(toggling.summary, "Updating…")
    }

    func testIsBuildingAndIsWaiting() {
        XCTAssertTrue(CIServingStatus(installed: true, serving: true, building: 1).isBuilding)
        XCTAssertTrue(CIServingStatus(installed: true, serving: true, waiting: 1).isWaiting)
        // Building takes precedence — a lane with a job running is not "just waiting".
        XCTAssertFalse(CIServingStatus(installed: true, serving: true, building: 1, waiting: 1).isWaiting)
    }

    // MARK: - Header roll-up (building green > waiting orange, summed)

    func testRunnerHeaderNoneAndOff() {
        XCTAssertEqual(RunnerHeaderState.from([
            CIServingStatus(installed: false, serving: false)]).kind, .none)
        XCTAssertFalse(RunnerHeaderState.from([
            CIServingStatus(installed: false, serving: false)]).isVisible)

        let off = RunnerHeaderState.from([CIServingStatus(installed: true, serving: false)])
        XCTAssertEqual(off.kind, .off)
        XCTAssertEqual(off.label, "runner off")
    }

    func testRunnerHeaderIdleWaitingBuilding() {
        XCTAssertEqual(RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: true)]).label, "serving")

        let waiting = RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: true, waiting: 1)])
        XCTAssertEqual(waiting.kind, .waiting)
        XCTAssertEqual(waiting.label, "waiting · 1")

        let building = RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: true, building: 1)])
        XCTAssertEqual(building.kind, .building)
        XCTAssertEqual(building.label, "building · 1")
    }

    func testRunnerHeaderSumsAcrossLanesAndBuildingWins() {
        // macOS waiting(1) + Linux building(1) → header shows building (green) total.
        let state = RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: true, waiting: 1),                 // macOS
            CIServingStatus(installed: true, serving: true, building: 1, waiting: 1),    // linux
        ])
        XCTAssertEqual(state.kind, .building)
        XCTAssertEqual(state.label, "building · 1")

        // Two lanes each waiting → SUM (distinct runners), not max.
        let waiting = RunnerHeaderState.from([
            CIServingStatus(installed: true, serving: true, waiting: 1),
            CIServingStatus(installed: true, serving: true, waiting: 1),
        ])
        XCTAssertEqual(waiting.label, "waiting · 2")
    }

    func testRunnerHeaderUpdatingDuringToggle() {
        var toggling = CIServingStatus(installed: true, serving: false)
        toggling.isToggling = true
        let state = RunnerHeaderState.from([toggling])
        XCTAssertEqual(state.kind, .updating)
        XCTAssertEqual(state.label, "updating…")
    }

    // MARK: - Runner-activity parsing (busy → building, online idle → waiting)

    private let runnersJSON = """
    {"total_count":4,"runners":[
      {"name":"ephr-1","status":"online","busy":true,
       "labels":[{"name":"self-hosted"},{"name":"macOS"},{"name":"ARM64"},{"name":"pulp-build"},{"name":"pulp-build-m5"}]},
      {"name":"ephr-2","status":"online","busy":false,
       "labels":[{"name":"self-hosted"},{"name":"macOS"},{"name":"ARM64"},{"name":"pulp-build"},{"name":"pulp-build-m5"}]},
      {"name":"studio-1","status":"online","busy":true,
       "labels":[{"name":"self-hosted"},{"name":"macOS"},{"name":"ARM64"},{"name":"pulp-build"},{"name":"pulp-build-studio"}]},
      {"name":"ephr-3","status":"offline","busy":false,
       "labels":[{"name":"self-hosted"},{"name":"macOS"},{"name":"ARM64"},{"name":"pulp-build"},{"name":"pulp-build-m5"}]}
    ]}
    """

    func testParseRunnerActivityMatchesLaneLabelsCaseInsensitively() {
        // The M5 macOS lane (labels include pulp-build-m5): 1 busy (building),
        // 1 idle (waiting). The studio runner and the offline one are excluded.
        let (building, waiting) = CIServingService.parseRunnerActivity(
            runnersJSON, laneLabels: ["self-hosted", "macos", "arm64", "pulp-build", "pulp-build-m5"])
        XCTAssertEqual(building, 1)
        XCTAssertEqual(waiting, 1)
    }

    func testParseRunnerActivityExcludesOtherMachinesAndOffline() {
        // The studio lane sees only its own busy runner; none waiting.
        let (building, waiting) = CIServingService.parseRunnerActivity(
            runnersJSON, laneLabels: ["self-hosted", "macos", "arm64", "pulp-build", "pulp-build-studio"])
        XCTAssertEqual(building, 1)
        XCTAssertEqual(waiting, 0)
    }

    func testParseRunnerActivityHandlesPaginatedSlurpArray() {
        // `gh api --paginate --slurp` wraps page objects in an array; a busy
        // runner on page 2 must still be counted (the per_page=100 bug).
        let slurped = """
        [
          {"total_count":100,"runners":[
            {"name":"p1","status":"online","busy":false,
             "labels":[{"name":"self-hosted"},{"name":"Linux"},{"name":"ARM64"},{"name":"pulp-build-linux"}]}]},
          {"total_count":100,"runners":[
            {"name":"p2","status":"online","busy":true,
             "labels":[{"name":"self-hosted"},{"name":"Linux"},{"name":"ARM64"},{"name":"pulp-build-linux"}]}]}
        ]
        """
        let (building, waiting) = CIServingService.parseRunnerActivity(
            slurped, laneLabels: ["self-hosted", "linux", "arm64", "pulp-build-linux"])
        XCTAssertEqual(building, 1)   // the page-2 busy runner
        XCTAssertEqual(waiting, 1)
    }

    func testMatchingRunnersReturnIdsForCrossRepoDedup() {
        // Same runner id appearing in two repo listings must be dedup-able by the
        // caller (activity sums into a dict keyed by id) — here we assert the
        // matcher surfaces a stable id + busy flag.
        let matched = CIServingService.matchingRunners(
            runnersJSON, laneLabels: ["self-hosted", "macos", "arm64", "pulp-build", "pulp-build-m5"])
        // ephr-1 (busy) + ephr-2 (idle); studio + offline excluded.
        XCTAssertEqual(matched.count, 2)
        XCTAssertEqual(matched.filter { $0.busy }.count, 1)
        XCTAssertTrue(matched.allSatisfy { !$0.id.isEmpty })
    }

    func testParseRunnerActivityEmptyInputs() {
        XCTAssertEqual(CIServingService.parseRunnerActivity("", laneLabels: ["x"]).building, 0)
        XCTAssertEqual(CIServingService.parseRunnerActivity("{}", laneLabels: ["x"]).waiting, 0)
        // No lane labels → nothing matches (don't count every runner).
        XCTAssertEqual(CIServingService.parseRunnerActivity(runnersJSON, laneLabels: []).building, 0)
    }

    // MARK: - Lane runner-label parsing from a plist

    func testRunnerLabelsParsedFromPlistProgramArguments() throws {
        let tmp = NSTemporaryDirectory() + "ci-lane-\(UUID().uuidString).plist"
        let plist: [String: Any] = [
            "Label": "com.example.runner",
            "ProgramArguments": ["/bin/bash", "/x/runner.sh", "--loop",
                                 "--labels", "self-hosted,Linux,ARM64,pulp-build,pulp-build-linux"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let lane = CIServingLane(id: "linux", platform: "Linux",
                                 agentLabel: "com.example.runner", plistPath: tmp)
        XCTAssertEqual(lane.runnerLabels(),
                       ["self-hosted", "Linux", "ARM64", "pulp-build", "pulp-build-linux"])
        // Missing plist → empty (don't crash; lane just shows no activity).
        let absent = CIServingLane(id: "x", platform: "X", agentLabel: "y",
                                   plistPath: "/no/such.plist")
        XCTAssertEqual(absent.runnerLabels(), [])
    }

    // MARK: - Lane catalog (per-host discovery from LaunchAgents)

    func testDiscoverFindsRunnerLanesAndExcludesBackups() throws {
        let tmp = NSTemporaryDirectory() + "la-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let files = [
            "com.danielraffel.pulp.tart-runner.plist",                      // gate → macOS · gate
            "com.danielraffel.pulp.tart-runner-sanitizer-macos.plist",      // macOS · sanitizer
            "com.danielraffel.pulp.tart-runner-linux.plist",                // Linux
            "com.danielraffel.pulp.qemu-runner-windows.plist",              // Windows
            "com.danielraffel.pulp.tart-runner-macos-pilot.plist.disabled", // excluded (not .plist suffix)
            "com.danielraffel.pulp.tart-runner.plist.pre-phase6",           // excluded (backup)
            "com.apple.something.plist",                                     // excluded (wrong prefix)
            "com.danielraffel.pulp.launchd-home-proof.plist",               // excluded (not a runner)
        ]
        for f in files { FileManager.default.createFile(atPath: tmp + "/" + f, contents: nil) }

        let lanes = CIServingLane.discover(agentsDirectory: tmp)

        XCTAssertEqual(lanes.count, 4)
        XCTAssertEqual(lanes.map(\.platform),
                       ["Linux", "Windows", "macOS · gate", "macOS · sanitizer"])
        XCTAssertFalse(lanes.contains {
            $0.id.contains("disabled") || $0.id.contains("pre-phase6")
                || $0.id.hasPrefix("com.apple") || $0.id.contains("launchd-home-proof")
        })
        let gate = try XCTUnwrap(lanes.first { $0.platform == "macOS · gate" })
        XCTAssertEqual(gate.agentLabel, "com.danielraffel.pulp.tart-runner")
        XCTAssertEqual(gate.plistPath, tmp + "/com.danielraffel.pulp.tart-runner.plist")
    }

    func testDiscoverEmptyDirIsEmpty() throws {
        let tmp = NSTemporaryDirectory() + "la-empty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        XCTAssertEqual(CIServingLane.discover(agentsDirectory: tmp).count, 0)
    }

    func testLaneNameInfersPlatformFromLabel() {
        let n = CIServingLane.laneName
        XCTAssertEqual(n("com.danielraffel.pulp.qemu-runner-windows"), "Windows")
        XCTAssertEqual(n("com.danielraffel.pulp.tart-runner-linux"), "Linux")
        XCTAssertEqual(n("com.danielraffel.pulp.tart-runner-sanitizer-macos"), "macOS · sanitizer")
        XCTAssertEqual(n("com.danielraffel.pulp.tart-runner-coverage"), "macOS · coverage")
        XCTAssertEqual(n("com.danielraffel.pulp.tart-runner-release-cli"), "macOS · release")
        XCTAssertEqual(n("com.danielraffel.pulp.tart-runner"), "macOS · gate")
        XCTAssertEqual(n("com.danielraffel.pulp.tart-runner-weird"), "macOS · tart-runner-weird")
    }
}
