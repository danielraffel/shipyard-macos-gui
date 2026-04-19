import SwiftUI

struct TargetRowView: View {
    let target: Target
    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(target.status.symbol)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(symbolColor)
                .frame(width: 14)

            Text(target.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(target.advisory ? .secondary : .primary)

            if let runner = target.runner {
                providerPill(for: runner)
            }

            Spacer()

            metadata
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func providerPill(for runner: Runner) -> some View {
        let color: Color = {
            switch runner.provider {
            case .local: return .green
            case .ssh: return .blue
            case .github: return .purple
            case .namespace: return .orange
            }
        }()
        HStack(spacing: 3) {
            Text(runner.provider.icon)
                .font(.system(size: 9, weight: .bold))
            Text(runner.label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            if target.status == .running {
                Text("\(target.phase.rawValue) · \(target.elapsedSeconds)s")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("last_seen=\(target.heartbeatAgeSeconds)s_ago")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(target.isStale ? Color.red : Color.secondary.opacity(0.7))
            } else if let fc = target.failureClass {
                Text(fc.rawValue)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(fc == .infra || fc == .timeout ? .orange : .red)
            } else if let reused = target.reusedFrom {
                Text("reused from \(String(reused.prefix(7)))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.purple)
            }
        }
    }

    private var symbolColor: Color {
        switch target.status {
        case .passed: return .green
        case .failed: return .red
        case .running: return target.isStale ? .orange : .blue
        case .reused: return .purple
        case .skipped, .pending: return .secondary
        }
    }
}
