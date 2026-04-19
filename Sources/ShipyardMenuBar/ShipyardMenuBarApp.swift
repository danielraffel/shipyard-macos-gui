import SwiftUI

@main
struct ShipyardMenuBarApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        // Use the simple systemImage: initializer — AppKit handles
        // template tinting and sizing automatically for this form.
        // Status indication lives in the popover header (colored dot
        // next to "Shipyard"), not in the menu-bar glyph itself.
        MenuBarExtra("Shipyard", systemImage: menuBarSymbol) {
            PopoverView()
                .environmentObject(store)
                .frame(width: 420, height: 560)
        }
        .menuBarExtraStyle(.window)
    }

    /// Anchor for normal state; an urgent triangle when a ship failed.
    /// This is a deliberately small information channel — the dominant
    /// status feedback is the popover header and the per-card pills.
    private var menuBarSymbol: String {
        switch store.overallBadge {
        case .failed: return "exclamationmark.triangle.fill"
        default: return "anchor"
        }
    }
}
