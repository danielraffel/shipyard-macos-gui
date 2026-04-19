import SwiftUI

@main
struct ShipyardMenuBarApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
                .frame(width: 420, height: 560)
        } label: {
            MenuBarLabelView(badge: store.overallBadge)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(minWidth: 480, minHeight: 360)
        }
    }
}
