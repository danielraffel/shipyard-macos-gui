import SwiftUI

struct MenuBarLabelView: View {
    let badge: OverallBadge

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "anchor")
                .imageScale(.medium)
            if let sym = badge.symbol {
                Text(sym)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(badgeColor, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private var badgeColor: Color {
        switch badge {
        case .failed: return .red
        case .allGreen: return .green
        case .running: return .blue
        case .idle: return .clear
        }
    }
}
