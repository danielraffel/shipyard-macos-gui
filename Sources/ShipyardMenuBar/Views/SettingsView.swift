import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            cliSection
            liveUpdatesSection
            githubSection
            notificationsSection
            autoClearSection
            displaySection
            developerSection
        }
        .formStyle(.grouped)
    }

    private var liveUpdatesSection: some View {
        Section("Live updates") {
            Picker("Mode", selection: $store.liveUpdateMode) {
                ForEach(LiveUpdateMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(modeDescription(for: store.liveUpdateMode))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            liveStatusRow
        }
    }

    /// Per-mode help text. Auto describes the fallback behavior
    /// explicitly so users don't assume realtime is guaranteed when
    /// Tailscale isn't ready.
    private func modeDescription(for mode: LiveUpdateMode) -> String {
        switch mode {
        case .auto:
            return "Near-realtime CI updates via webhooks when Tailscale Funnel is available. Falls back to polling every 60s when it isn't. We configure the tunnel and webhooks for you."
        case .on:
            return "Require near-realtime updates via Tailscale Funnel. Shows a warning and falls back to polling if Tailscale isn't available. We configure the tunnel and webhooks for you."
        case .off:
            return "Polling every 60s. No webhooks registered, no tunnel. Use Auto for live updates when Tailscale is available."
        }
    }

    @ViewBuilder
    private var liveStatusRow: some View {
        switch store.liveStatus {
        case .live(let url, let lastEventAt):
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Live · via Tailscale Funnel")
                        .font(.system(size: 11, weight: .medium))
                    Text(liveStatusDetail(url: url, lastEventAt: lastEventAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .polling(let reason):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: pollingIcon(for: reason))
                    .foregroundStyle(pollingTint(for: reason))
                VStack(alignment: .leading, spacing: 1) {
                    Text(pollingTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(pollingTint(for: reason))
                    if let reason {
                        Text(reason.userFacing)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var pollingTitle: String {
        if case .polling(let reason) = store.liveStatus,
           reason != nil,
           store.liveUpdateMode == .on {
            return "Warning — falling back to polling"
        }
        return "Polling every 60s"
    }

    private func pollingIcon(for reason: LiveUpdateStatus.PollingReason?) -> String {
        if store.liveUpdateMode == .on && reason != nil {
            return "exclamationmark.triangle.fill"
        }
        return "arrow.clockwise"
    }

    private func pollingTint(for reason: LiveUpdateStatus.PollingReason?) -> Color {
        if store.liveUpdateMode == .on && reason != nil {
            return .orange
        }
        return .secondary
    }

    private func liveStatusDetail(url: URL, lastEventAt: Date?) -> String {
        if let last = lastEventAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return "last event \(f.localizedString(for: last, relativeTo: Date()))"
        }
        return "waiting for first event · \(url.host ?? url.absoluteString)"
    }

    private var githubSection: some View {
        Section("GitHub Actions") {
            Toggle("Show runs from github.com", isOn: $store.showGitHubActions)
                .help("Polls `gh run list` every 60s for each repo you've shipped from this machine")
            Picker("Time window", selection: $store.ghWindowMinutes) {
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
                Text("1 day").tag(1440)
                Text("7 days").tag(10080)
            }
            .disabled(!store.showGitHubActions)
            TextField("Hide workflows matching", text: $store.ghWorkflowBlocklist,
                      prompt: Text("e.g. post-tag-sync, changelog"))
                .help("Comma-separated substrings. A run is hidden when its workflow name contains any of these.")
                .disabled(!store.showGitHubActions)
            Text("Runs already represented by a local ship card are auto-deduplicated by head_sha.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var cliSection: some View {
        Section("Shipyard CLI") {
            // Row 1: resolved-path status (green) or error (orange).
            if let resolved = store.cliBinaryResolved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(resolved)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(store.cliBinaryPath.isEmpty ? "auto-detected" : "overridden")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .italic()
                }
            } else if let err = store.cliBinaryError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Spacer()
                    Link("Install →",
                         destination: URL(string: "https://github.com/danielraffel/Shipyard#installation")!)
                        .font(.system(size: 11, weight: .medium))
                }
            }

            // Row 2: single-line override input + two differentiated buttons.
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $store.cliBinaryPath,
                    prompt: Text("e.g. /opt/homebrew/bin/shipyard")
                        .font(.system(size: 11, design: .monospaced))
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .labelsHidden()

                Button("Choose…", action: browse)
                    .help("Open a file picker to locate the shipyard binary")

                Button("Detect") { store.resolveCLIBinary() }
                    .help("Re-scan the standard install paths (/usr/local/bin, /opt/homebrew/bin, ~/.pulp/bin, ~/.local/bin)")
            }

            Text("Leave empty to auto-detect on next launch.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Ship fails", isOn: $store.notifyOnFail)
            Toggle("All green", isOn: $store.notifyOnGreen)
            Toggle("Merge complete", isOn: $store.notifyOnMerge)
        }
    }

    private var autoClearSection: some View {
        Section("Auto-clear") {
            Picker("Passed ships", selection: $store.autoClearPassedMinutes) {
                Text("30 min").tag(30)
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
                Text("Never").tag(0)
            }
            Picker("Failed ships", selection: $store.autoClearFailedMinutes) {
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
                Text("1 day").tag(1440)
                Text("Never").tag(0)
            }
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Toggle("Group ships by worktree", isOn: $store.groupByWorktree)
            Toggle("Auto-expand active PRs", isOn: $store.autoExpandActivePRs)
            Text("When on, PRs with shipyard targets or recent GitHub Actions runs open by default. Your manual expand/collapse choices are always respected.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Toggle("Resume prompt on wake", isOn: $store.resumePromptOnWake)
        }
    }

    private var developerSection: some View {
        Section("Developer") {
            Toggle("Show demo data", isOn: $store.showDemoData)
            Text("Replaces live polling with fixture PRs. Useful for previewing the UI when nothing is in flight.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            store.cliBinaryPath = url.path
        }
    }
}
