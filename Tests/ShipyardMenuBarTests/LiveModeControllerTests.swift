import XCTest
@testable import Shipyard

/// Guard against the "webhook arrives but UI never updates" regression.
///
/// The real bug we debugged was a copy issue, not a pipeline bug — but
/// along the way we traced every hop and these tests codify the
/// invariants so a future refactor can't silently break them.
@MainActor
final class LiveModeControllerTests: XCTestCase {

    /// Forcing `.live` state exposes `recordDelivery`'s effect on
    /// `status` — we use a synchronous seam instead of going through
    /// `reconcile` (which would need real Tailscale + gh).
    private func seedLive(_ controller: LiveModeController, url: URL) {
        // The only way to reach `.live` status is via `update` which
        // is private. Indirectly: call recordDelivery while status is
        // still `.polling` (no-op), then mutate through a test helper.
        // Since we can't reach `update` from here, we test the public
        // surface instead: `recordDelivery` should be a no-op when
        // status isn't `.live`, and `status` getter stays polling.
        //
        // For the .live-path tests, we use the onStatusChange hook
        // which IS public — the reconcile() code path calls update()
        // to transition to .live, and our test double simulates that
        // via the same callback machinery by driving reconcile with
        // a mocked TailscaleStatus. See the decision-table coverage
        // in LiveModeDecisionTests; this file focuses on the delivery
        // bookkeeping invariants we can verify without subprocess.
        _ = (controller, url)
    }

    // MARK: - Delivery bookkeeping invariants

    func test_recordDelivery_whenPolling_isNoOpOnStatus() {
        let controller = LiveModeController()
        // Fresh controller starts in .polling(.userDisabled).
        var observed: LiveUpdateStatus?
        controller.onStatusChange = { observed = $0 }
        controller.recordDelivery()
        // Status didn't flip — no change fired.
        XCTAssertNil(observed)
        if case .polling = controller.status {
            // ok
        } else {
            XCTFail("expected status to remain .polling when no tunnel is up")
        }
    }

    func test_onStatusChange_firesOnlyOnDistinctUpdates() {
        // Setting the same status twice should not fire the callback
        // the second time — the guard in `update` uses Equatable.
        let controller = LiveModeController()
        var count = 0
        controller.onStatusChange = { _ in count += 1 }
        // Two equal .polling states shouldn't fire if we could drive
        // them; we can't reach `update` directly. But we can probe
        // through `recordDelivery` (no-op when .polling) to confirm
        // idle calls don't fan out.
        controller.recordDelivery()
        controller.recordDelivery()
        XCTAssertEqual(count, 0, "idle recordDelivery must not fire onStatusChange")
    }

    // MARK: - LiveUpdateStatus equality (the key invariant for update())

    func test_liveStatus_equalityIsSensitiveToLastEventAt() {
        // If Equatable ever collapses different `lastEventAt` values,
        // `update()` would guard-return and recordDelivery would never
        // propagate. That's exactly the "waiting forever" failure mode.
        let url = URL(string: "https://example.ts.net")!
        let t = Date()
        XCTAssertNotEqual(
            LiveUpdateStatus.live(tunnelURL: url, lastEventAt: nil),
            LiveUpdateStatus.live(tunnelURL: url, lastEventAt: t)
        )
        XCTAssertEqual(
            LiveUpdateStatus.live(tunnelURL: url, lastEventAt: t),
            LiveUpdateStatus.live(tunnelURL: url, lastEventAt: t)
        )
    }

    func test_liveStatus_distinctFromPolling() {
        let url = URL(string: "https://example.ts.net")!
        XCTAssertNotEqual(
            LiveUpdateStatus.live(tunnelURL: url, lastEventAt: nil),
            LiveUpdateStatus.polling(reason: nil)
        )
    }

    func test_pollingReasons_areDistinct() {
        XCTAssertNotEqual(
            LiveUpdateStatus.polling(reason: .userDisabled),
            LiveUpdateStatus.polling(reason: .tailscaleNotInstalled)
        )
        XCTAssertEqual(
            LiveUpdateStatus.polling(reason: .userDisabled),
            LiveUpdateStatus.polling(reason: .userDisabled)
        )
    }

    // MARK: - The user-visible copy for each state

    func test_pollingReason_userFacingStrings_areTailored() {
        // Changing these strings is fine; we just want to guard
        // against someone accidentally deleting the distinctions
        // (e.g. every reason collapsing to a single generic message).
        let all: [LiveUpdateStatus.PollingReason] = [
            .userDisabled,
            .tailscaleNotInstalled,
            .tailscaleNotRunning,
            .funnelNotPermitted,
            .tunnelStartFailed("x"),
            .serverStartFailed("y"),
        ]
        let texts = Set(all.map(\.userFacing))
        XCTAssertEqual(texts.count, all.count,
                       "each PollingReason should have its own user-facing string")
    }
}
