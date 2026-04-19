import SwiftUI

@main
struct ShipyardMenuBarApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        // MenuBarExtra renders a template NSImage under the hood; the
        // systemImage: initializer is the proven path for AppKit's
        // auto-tinting (white on dark menu bar, black on light).
        //
        // We pass a STATIC symbol name. Dynamic symbol switching by
        // computed property is unreliable here — macOS sometimes
        // caches the first-resolved NSImage and later updates render
        // as a generic black blob. Status indication lives in the
        // popover header instead.
        MenuBarExtra("Shipyard", systemImage: "anchor") {
            PopoverView()
                .environmentObject(store)
                .frame(width: 420, height: 560)
        }
        .menuBarExtraStyle(.window)
    }
}
