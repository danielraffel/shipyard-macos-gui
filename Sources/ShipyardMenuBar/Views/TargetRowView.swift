import SwiftUI

struct TargetRowView: View {
    let target: Target
    let ship: Ship
    @EnvironmentObject var store: AppStore
    @State private var hovering: Bool = false
    @State private var pickerOpen: Bool = false
    @State private var logsOpen: Bool = false

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
            if logsOpen {
                LogPaneView(
                    target: target,
                    ship: ship,
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.18)) { logsOpen = false }
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

            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { logsOpen.toggle() }
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(target.runId == nil)
                .help(target.runId == nil
                      ? "Logs become available once the run has started"
                      : "Show logs inline (shipyard logs \(target.runId ?? ""))")
            }
            .opacity(hovering || logsOpen ? 1 : 0)
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

    @ViewBuilder
    private var metadata: some View {
        if target.status == .running {
            HStack(spacing: 6) {
                Text(target.phase.rawValue)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(target.elapsedSeconds)s")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                if target.heartbeatAgeSeconds > 0 {
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(target.heartbeatAgeSeconds)s ago")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(target.isStale ? ShipyardColors.red : Color.secondary.opacity(0.7))
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        } else if let fc = target.failureClass {
            Text(fc.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(fc.tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(fc.tint.opacity(0.15), in: Capsule())
        } else if let reused = target.reusedFrom {
            Text("reused \(String(reused.prefix(7)))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ShipyardColors.purple)
        } else if target.advisory {
            Text("advisory")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .italic()
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
