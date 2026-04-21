import AppKit
import SwiftUI

/// Hand-rolled NSStatusItem + NSPopover host. `MenuBarExtra`'s template-
/// image path has been unreliable (solid black circle instead of the
/// anchor glyph) on recent macOS/SwiftUI combos. Managing the status
/// item ourselves guarantees correct template tinting.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // SF Symbol "anchor" is the reliable path — it's
            // guaranteed to load, guaranteed to template-tint (white
            // on dark menu bar, black on light). We dropped the
            // custom SVG asset and Unicode fallback because both
            // were failing on this macOS build and the Unicode
            // character falls through as a full-color emoji which
            // looks nothing like the rest of the menu bar.
            let image = NSImage(
                systemSymbolName: "anchor",
                accessibilityDescription: "Shipyard"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.action = #selector(handleClick(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().environmentObject(store)
                .frame(width: 420, height: 560)
        )
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .minY
            )
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func show() {
        if let button = statusItem.button, !popover.isShown {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }
}
