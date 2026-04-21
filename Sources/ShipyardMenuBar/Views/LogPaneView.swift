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
        if let ghRunId = target.githubRunId, let repo = target.githubRepo {
            // GitHub-sourced: `gh run view <id> --log` in Terminal.
            let script = "tell application \"Terminal\" to do script \"gh run view \(ghRunId) --repo \(repo) --log; echo; echo '--- press any key to close ---'; read -n 1\""
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            try? task.run()
            return
        }
        guard let binary = store.cliBinaryResolved else { return }
        guard let jobId = target.runId else { return }
        let script = "tell application \"Terminal\" to do script \"\(binary) logs \(jobId) --target \(target.name); echo; echo '--- press any key to close ---'; read -n 1\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        // Route based on target source — GitHub-backed targets go
        // through `gh run view --log`, shipyard-native go through
        // `shipyard logs`.
        if let ghRunId = target.githubRunId, let repo = target.githubRepo {
            let raw = await runGHCapturing(
                executable: resolveGH() ?? "/opt/homebrew/bin/gh",
                args: ["run", "view", "\(ghRunId)", "--repo", repo, "--log"]
            )
            if raw.isEmpty {
                output = "No log content returned by gh. The run may have expired or the job isn't complete yet."
            } else {
                // gh's --log is big; only keep the tail for the
                // inline pane. "Open in Terminal" is the power path.
                let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
                let tail = lines.suffix(200).joined(separator: "\n")
                output = tail
            }
            return
        }
        guard let binary = store.cliBinaryResolved else {
            output = "shipyard CLI not available."
            return
        }
        guard let jobId = target.runId else {
            output = "No run ID recorded for this target yet. Logs are available once the run has started."
            return
        }
        let out = await runShipyardCapturingStdout(binary: binary, args: [
            "logs", jobId,
            "--target", target.name,
        ])
        if out.isEmpty {
            output = "(no output)"
            return
        }
        if out.contains("not found") {
            output = "Logs for \(jobId) are no longer available — the queue has rolled past this run. Use `shipyard queue --json` to see what's still retained."
        } else {
            output = out
        }
    }

    private func resolveGH() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
