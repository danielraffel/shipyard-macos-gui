import SwiftUI
import AppKit

@main
struct ShipyardMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // MenuBarExtra isn't used — AppDelegate owns the NSStatusItem
    // directly (see StatusItemController). This gives us reliable
    // template-image tinting that MenuBarExtra's `systemImage:` path
    // has been failing to deliver.
    //
    // We still declare a Settings scene so ⌘, in the main menu has
    // somewhere to go, but we leave it empty: all real settings live
    // in the popover's Settings tab.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    var statusItem: StatusItemController?
    /// Strongly held so Sparkle's daily-check timer + download/
    /// install flow stays alive for the app's lifetime. Losing the
    /// reference would silently disable auto-updates.
    let autoUpdate = AutoUpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.autoUpdate = autoUpdate
        statusItem = StatusItemController(store: store)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
