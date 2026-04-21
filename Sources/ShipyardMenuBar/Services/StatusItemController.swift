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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Per user request: use "arrow.trianglehead.merge" for
            // now. SF Symbol "anchor" was rendering invisibly on
            // this macOS build for reasons I couldn't diagnose.
            // merge-arrow is visible + on-theme (we're a CI tool).
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let candidates = ["arrow.trianglehead.merge", "arrow.triangle.merge", "anchor"]
            var image: NSImage?
            for name in candidates {
                if let img = NSImage(systemSymbolName: name,
                                     accessibilityDescription: "Shipyard")?
                    .withSymbolConfiguration(config) {
                    img.isTemplate = true
                    img.size = NSSize(width: 18, height: 18)
                    image = img
                    break
                }
            }
            button.image = image
            button.title = ""
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
