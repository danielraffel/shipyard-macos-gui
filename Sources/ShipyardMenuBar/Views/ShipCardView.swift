import SwiftUI

struct ShipCardView: View {
    let ship: Ship
    @EnvironmentObject var store: AppStore
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded {
                ForEach(ship.targets) { target in
                    TargetRowView(target: target)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Text(ship.repo)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Link(destination: prURL) {
                Text("#\(ship.prNumber)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            Text(ship.branch)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            statusPill
        }
    }

    private var statusPill: some View {
        let label: String
        let color: Color
        switch ship.overallStatus {
        case .passed: label = "green"; color = .green
        case .failed: label = "failed"; color = .red
        case .running: label = "running"; color = .blue
        case .reused: label = "reused"; color = .purple
        case .skipped: label = "skipped"; color = .gray
        case .pending: label = "pending"; color = .gray
        }
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var prURL: URL {
        URL(string: "https://github.com/\(ship.repo)/pull/\(ship.prNumber)") ?? URL(string: "https://github.com")!
    }
}
