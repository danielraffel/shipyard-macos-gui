import SwiftUI

/// Menu-bar label. Must render as a template image so macOS auto-tints
/// it white/black depending on menu bar background. The trick: don't
/// override foregroundStyle or symbolRenderingMode — let SwiftUI/AppKit
/// do their template-image handling for MenuBarExtra.
struct MenuBarLabelView: View {
    let badge: OverallBadge

    var body: some View {
        Image(systemName: "anchor")
            .overlay(alignment: .topTrailing) {
                if badge != .idle {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                        .offset(x: 3, y: -1)
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }

    private var dotColor: Color {
        switch badge {
        case .failed: return .red
        case .allGreen: return .green
        case .running: return .blue
        case .idle: return .clear
        }
    }

    private var accessibilityLabel: String {
        switch badge {
        case .idle: return "Shipyard — no ships in flight"
        case .running: return "Shipyard — ships running"
        case .allGreen: return "Shipyard — all green"
        case .failed: return "Shipyard — ship failed"
        }
    }
}
