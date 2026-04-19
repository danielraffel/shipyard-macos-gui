import SwiftUI

struct TargetRowView: View {
    let target: Target
    let ship: Ship
    @EnvironmentObject var store: AppStore
    @State private var hovering: Bool = false
    @State private var pickerOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if pickerOpen {
                RunnerPickerView(
                    target: target,
                    ship: ship,
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            pickerOpen = false
                        }
                    }
                )
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text(target.status.symbol)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(symbolColor)
                .frame(width: 14)

            Text(target.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(target.advisory ? .secondary : .primary)

            if let runner = target.runner {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        pickerOpen.toggle()
                    }
                } label: {
                    providerPill(for: runner)
                }
                .buttonStyle(.plain)
                .help("Click to retarget")
            }

            Spacer()

            metadata

            HStack(spacing: 4) {
                if target.status == .failed {
                    Button {
                        openLogsInTerminal()
                    } label: {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Open logs in Terminal")
                }
            }
            .opacity(hovering ? 1 : 0)
            .frame(width: 20, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }

    private func openLogsInTerminal() {
        guard let binary = store.cliBinaryResolved else { return }
        // Spawn Terminal.app with `shipyard logs <pr> --target <name>`.
        let script = "tell application \"Terminal\" to do script \"\(binary) logs \(ship.prNumber) --target \(target.name); echo; echo '--- press any key to close ---'; read -n 1\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    @ViewBuilder
    private func providerPill(for runner: Runner) -> some View {
        let color = runner.provider.tint
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
                if target.heartbeatAgeSeconds > 0 {
                    Text("last_seen=\(target.heartbeatAgeSeconds)s")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(target.isStale ? ShipyardColors.red : Color.secondary.opacity(0.7))
                }
            } else if let fc = target.failureClass {
                Text(fc.rawValue)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(fc.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(fc.tint.opacity(0.15), in: Capsule())
            } else if let reused = target.reusedFrom {
                Text("reused from \(String(reused.prefix(7)))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(ShipyardColors.purple)
            }
        }
    }

    private var symbolColor: Color {
        switch target.status {
        case .passed: return ShipyardColors.green
        case .failed: return ShipyardColors.red
        case .running: return target.isStale ? ShipyardColors.orange : ShipyardColors.blue
        case .reused: return ShipyardColors.purple
        case .skipped, .pending: return .secondary
        }
    }
}
