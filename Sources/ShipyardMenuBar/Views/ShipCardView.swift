import SwiftUI

struct ShipCardView: View {
    let ship: Ship
    @EnvironmentObject var store: AppStore
    @State private var expanded: Bool = true
    @State private var hovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded {
                ForEach(ship.targets) { target in
                    TargetRowView(target: target, ship: ship)
                }
                footer
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
        .onHover { hovering = $0 }
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

            if !ship.repo.isEmpty {
                Text(ship.repo)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
            }

            Link(destination: prURL) {
                Text("#\(ship.prNumber)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            if !ship.branch.isEmpty {
                Text(ship.branch)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            statusPill

            if ship.overallStatus == .passed || ship.overallStatus == .failed {
                Button {
                    store.dismiss(ship: ship)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .opacity(hovering ? 1 : 0.4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !ship.worktree.isEmpty {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(ship.worktree)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if ship.overallStatus == .running {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(relative(ship.startedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
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
        guard !ship.repo.isEmpty else {
            return URL(string: "https://github.com")!
        }
        return URL(string: "https://github.com/\(ship.repo)/pull/\(ship.prNumber)")
            ?? URL(string: "https://github.com")!
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
