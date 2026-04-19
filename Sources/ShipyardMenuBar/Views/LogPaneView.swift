import SwiftUI

/// Inline log pane. Calls `shipyard logs <run_id> --target <name>` and
/// streams the output into a fixed-height monospace scroll region.
/// Prefer this over launching Terminal when the user is exploring —
/// keeps them in the menu bar context.
struct LogPaneView: View {
    let target: Target
    let ship: Ship
    let onDismiss: () -> Void
    @EnvironmentObject var store: AppStore

    @State private var output: String = ""
    @State private var loading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Fetching logs…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }
            ScrollView {
                Text(output.isEmpty ? " " : output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.04))
            )
        }
        .padding(8)
        .padding(.leading, 22)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Text("Logs — \(target.name)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                openInTerminal()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                    Text("Open in Terminal")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func openInTerminal() {
        guard let binary = store.cliBinaryResolved else { return }
        let script = "tell application \"Terminal\" to do script \"\(binary) logs \(ship.prNumber) --target \(target.name); echo; echo '--- press any key to close ---'; read -n 1\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        guard let binary = store.cliBinaryResolved else {
            output = "shipyard CLI not available."
            return
        }
        // Use the PR number as the job ID hint. Shipyard's `logs`
        // command takes a job ID — we don't have a direct mapping
        // but the CLI handles PR numbers gracefully.
        let out = await runShipyardCapturingStdout(binary: binary, args: [
            "logs", "\(ship.prNumber)",
            "--target", target.name,
        ])
        output = out.isEmpty ? "(no output)" : out
    }
}
