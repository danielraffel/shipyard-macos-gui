import XCTest
@testable import Shipyard

/// Covers the decision table from issue #2 — how `LiveModeController`
/// maps (mode, tailscale-readiness) → (attemptLive, pollingReason).
final class LiveModeDecisionTests: XCTestCase {

    private func readyStatus() -> TailscaleStatus {
        TailscaleStatus(
            binaryPath: "/opt/homebrew/bin/tailscale",
            backendState: "Running",
            dnsName: "foo.ts.net",
            funnelPermitted: true
        )
    }

    private func notInstalled() -> TailscaleStatus {
        TailscaleStatus(binaryPath: nil, backendState: nil, dnsName: nil, funnelPermitted: false)
    }

    private func installedButStopped() -> TailscaleStatus {
        TailscaleStatus(
            binaryPath: "/opt/homebrew/bin/tailscale",
            backendState: "Stopped",
            dnsName: nil,
            funnelPermitted: false
        )
    }

    private func runningButNoFunnel() -> TailscaleStatus {
        TailscaleStatus(
            binaryPath: "/opt/homebrew/bin/tailscale",
            backendState: "Running",
            dnsName: "foo.ts.net",
            funnelPermitted: false
        )
    }

    // MARK: - Auto

    func test_auto_whenReady_attemptsLive() {
        let d = LiveModeController.decide(mode: .auto, tailscale: readyStatus())
        XCTAssertTrue(d.attemptLive)
        XCTAssertNil(d.reason)
    }

    func test_auto_whenNotInstalled_pollsWithoutPunishment() {
        let d = LiveModeController.decide(mode: .auto, tailscale: notInstalled())
        XCTAssertFalse(d.attemptLive)
        XCTAssertEqual(d.reason, .tailscaleNotInstalled)
    }

    func test_auto_whenStopped_pollsQuietly() {
        let d = LiveModeController.decide(mode: .auto, tailscale: installedButStopped())
        XCTAssertFalse(d.attemptLive)
        XCTAssertEqual(d.reason, .tailscaleNotRunning)
    }

    func test_auto_whenFunnelMissing_pollsQuietly() {
        let d = LiveModeController.decide(mode: .auto, tailscale: runningButNoFunnel())
        XCTAssertFalse(d.attemptLive)
        XCTAssertEqual(d.reason, .funnelNotPermitted)
    }

    // MARK: - On

    func test_on_whenReady_attemptsLive() {
        let d = LiveModeController.decide(mode: .on, tailscale: readyStatus())
        XCTAssertTrue(d.attemptLive)
        XCTAssertNil(d.reason)
    }

    func test_on_whenNotInstalled_surfacesReason() {
        // UI converts this reason + mode=.on into a visible warning;
        // the decision itself just reports the same reason as Auto.
        let d = LiveModeController.decide(mode: .on, tailscale: notInstalled())
        XCTAssertFalse(d.attemptLive)
        XCTAssertEqual(d.reason, .tailscaleNotInstalled)
    }

    // MARK: - Off

    func test_off_neverAttemptsLive_regardlessOfReadiness() {
        let d = LiveModeController.decide(mode: .off, tailscale: readyStatus())
        XCTAssertFalse(d.attemptLive)
        XCTAssertEqual(d.reason, .userDisabled)

        let d2 = LiveModeController.decide(mode: .off, tailscale: notInstalled())
        XCTAssertFalse(d2.attemptLive)
        XCTAssertEqual(d2.reason, .userDisabled)
    }
}
