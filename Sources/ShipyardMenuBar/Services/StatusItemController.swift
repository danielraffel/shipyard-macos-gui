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
            // Two-path icon: try SF Symbol with explicit size + template;
            // fall back to the Unicode anchor character as button title
            // if the symbol fails to load (zero-sized or nil on this
            // macOS build). The title path is guaranteed to render
            // something visible.
            if let base = NSImage(
                systemSymbolName: "anchor",
                accessibilityDescription: "Shipyard"
            ) {
                base.size = NSSize(width: 18, height: 18)
                base.isTemplate = true
                button.image = base
                button.imagePosition = .imageOnly
            } else {
                button.title = "\u{2693}" // ⚓
                button.imagePosition = .noImage
            }
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
