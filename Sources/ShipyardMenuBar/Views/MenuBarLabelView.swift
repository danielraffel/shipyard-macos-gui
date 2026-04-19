import SwiftUI

/// Menu-bar label. macOS renders this as a single template image, so we
/// keep it simple: the anchor symbol, optionally tinted by overall state.
///
/// The status dot is drawn as an inline overlay rather than a second text
/// element — nested HStack children can get clipped or not render at all
/// at the 18pt menu bar height on some Macs.
struct MenuBarLabelView: View {
    let badge: OverallBadge

    var body: some View {
        Image(systemName: "anchor")
            .symbolRenderingMode(.monochrome)
            .imageScale(.medium)
            .foregroundStyle(tint)
            .overlay(alignment: .topTrailing) {
                if badge != .idle {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }

    private var tint: Color {
        switch badge {
        case .failed: return .primary
        case .allGreen: return .primary
        case .running: return .primary
        case .idle: return .primary
        }
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
