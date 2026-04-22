import AppKit
import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Sparkle's default behavior does everything we need: check on
/// app launch, daily background checks, download + EdDSA-verify +
/// install via a signed DMG. The wrapper exists so SettingsView can
/// bind a "Check for Updates…" button without importing Sparkle
/// itself, and so we can publish the latest-check state / version
/// info via an ObservableObject without plumbing Sparkle's types
/// through SwiftUI.
///
/// The updater is instantiated once in AppDelegate. It owns the
/// lifecycle of the background daily-check timer defined in
/// `SUScheduledCheckInterval` (Info.plist).
@MainActor
final class AutoUpdateController: ObservableObject {
    /// Strongly-held so Sparkle's timers + background checks keep
    /// running. Losing this reference would silently disable auto
    /// updates.
    private let updaterController: SPUStandardUpdaterController

    /// Informational — what version of Sparkle we linked against.
    /// Surfaced in Settings so a user reporting an update bug can
    /// tell us which Sparkle version produced the behavior.
    var sparkleVersion: String {
        // Sparkle doesn't expose its own version at runtime in a
        // stable API across 2.x — we fall back to the framework's
        // CFBundleShortVersionString if we can find it.
        guard let bundle = Bundle(identifier: "org.sparkle-project.Sparkle"),
              let version = bundle.infoDictionary?["CFBundleShortVersionString"]
                as? String
        else { return "?" }
        return version
    }

    init() {
        // `startingUpdater: true` makes Sparkle begin its background
        // check schedule immediately. `updaterDelegate` / user-driver
        // delegate are nil → Sparkle uses its standard modal UI,
        // which is the right choice for a menu-bar app: the update
        // window appears in its own window, independent of any
        // popover / status-item state.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Kick off a manual update check. Sparkle shows its UI even
    /// when there's no update available (standard "you're up to
    /// date" dialog), which is the expected affordance for a
    /// "Check for Updates…" menu item.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Whether Sparkle will auto-check. Bound to the toggle in
    /// Settings so a privacy-minded user can disable the background
    /// check without touching UserDefaults directly.
    var automaticUpdateChecksEnabled: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }
}
