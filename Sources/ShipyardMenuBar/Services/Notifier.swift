import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter`. Stateless on purpose —
/// AppStore hands it the old and new badge, and it decides whether (and
/// how) to fire a notification based on the user's preferences.
enum Notifier {
    static func maybeNotify(
        from oldBadge: OverallBadge,
        to newBadge: OverallBadge,
        prefs: (fail: Bool, green: Bool, merge: Bool)
    ) {
        switch (oldBadge, newBadge) {
        case (_, .failed) where prefs.fail && oldBadge != .failed:
            deliver(
                title: "Shipyard",
                body: "A ship failed."
            )
        case (_, .allGreen) where prefs.green && oldBadge != .allGreen:
            deliver(
                title: "Shipyard",
                body: "All ships green."
            )
        // Merge notification trigger is "ship disappeared from tracking"
        // — which shows up as all-green → idle. Route that through the
        // merge toggle when that preference is on. (state-archived events
        // trigger ship removal in AppStore before we observe the badge.)
        case (.allGreen, .idle) where prefs.merge:
            deliver(
                title: "Shipyard",
                body: "Merge complete."
            )
        default:
            break
        }
    }

    private static var authorizationRequested = false

    private static func deliver(title: String, body: String) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            if !authorizationRequested {
                authorizationRequested = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(req)
        }
    }
}
