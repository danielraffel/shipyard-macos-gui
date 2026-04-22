import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            generalSection
            cliSection
            liveUpdatesSection
            githubSection
            notificationsSection
            autoClearSection
            displaySection
            #if DEBUG
            developerSection
            #endif
        }
        .formStyle(.grouped)
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch Shipyard at login", isOn: $store.launchAtLogin)
            Text(launchAtLoginFootnote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updates")
                        .font(.system(size: 11, weight: .medium))
                    Text("Shipyard checks for new versions daily and notifies you here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for Updates…") {
                    store.autoUpdate?.checkForUpdates()
                }
                .disabled(store.autoUpdate == nil)
                .help("Ask Sparkle to check the appcast feed now. Shows a dialog either way — update available or already current.")
            }
        }
    }

    /// Keep the user informed when the OS-level status disagrees with
    /// the toggle — usually because macOS prompted for approval and
    /// they deferred, or they flipped the switch in System Settings.
    private var launchAtLoginFootnote: String {
        if store.launchAtLogin {
            switch store.launchAtLoginSystemStatus {
            case .enabled:
                return "Shipyard will open automatically next time you log in."
            case .requiresApproval:
                return "macOS needs your approval in System Settings → General → Login Items."
            case .notRegistered, .notFound:
                return "Registration didn't take effect. Try toggling off and on again."
            @unknown default:
                return "Registration status is unknown — check System Settings → General → Login Items."
            }
        }
        return "Shipyard only starts when you open it manually."
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
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Live · via Tailscale Funnel")
                        .font(.system(size: 11, weight: .medium))
                    // Tick every second so the "last event Ns ago"
                    // string is a real counter, not a coarse 10s-bucket
                    // jump. Prior version used `.periodic(by: 10)` +
                    // `RelativeDateTimeFormatter(.short)`: the user saw
                    // "38 sec." freeze for many seconds at a time, then
                    // skip to "1 min." — it didn't look live at all,
                    // which is exactly the opposite signal we want when
                    // the whole purpose of this line is to show the
                    // tunnel is healthy.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(liveStatusDetail(
                            lastEventAt: lastEventAt, now: ctx.date
                        ))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    // URL on its own line so the hostname doesn't get
                    // middle-truncated away.
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
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

    private func liveStatusDetail(lastEventAt: Date?, now: Date = Date()) -> String {
        if let last = lastEventAt {
            return "last event \(formatAgeLive(since: last, now: now))"
        }
        // The tunnel is up + webhooks are registered — but we haven't
        // received a delivery since the app launched. Don't imply the
        // tunnel is broken; events only arrive when GitHub fires them.
        return "tunnel active · no events yet this session"
    }

    /// Hand-rolled age formatter that produces a real ticking counter.
    /// `RelativeDateTimeFormatter(.short)` rounds to word-scale units
    /// ("38 sec." → "1 min.") which defeats the purpose of a 1s tick.
    /// Output shape:
    ///   < 60s  → "3s ago"
    ///   < 1h   → "2m 05s ago"
    ///   < 24h  → "3h 04m ago"
    ///   ≥ 24h  → "2d ago"
    private func formatAgeLive(since: Date, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(since)))
        if secs < 60 {
            return "\(secs)s ago"
        }
        if secs < 3600 {
            let m = secs / 60
            let s = secs % 60
            return String(format: "%dm %02ds ago", m, s)
        }
        if secs < 86_400 {
            let h = secs / 3600
            let m = (secs % 3600) / 60
            return String(format: "%dh %02dm ago", h, m)
        }
        let days = secs / 86_400
        return "\(days)d ago"
    }

    private var githubSection: some View {
        Section("GitHub Actions") {
            Toggle("Show runs from github.com", isOn: $store.showGitHubActions)
                .help("Polls `gh run list` every 60s for each repo this machine has opened a PR from")
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
            Text("Runs already represented by a local PR card are auto-deduplicated by head_sha.")
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
            Toggle("PR fails", isOn: $store.notifyOnFail)
            Toggle("All green", isOn: $store.notifyOnGreen)
            Toggle("Merge complete", isOn: $store.notifyOnMerge)
        }
    }

    private var autoClearSection: some View {
        Section("Auto-clear") {
            Picker("Passed PRs", selection: $store.autoClearPassedMinutes) {
                Text("30 min").tag(30)
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
                Text("Never").tag(0)
            }
            Picker("Failed PRs", selection: $store.autoClearFailedMinutes) {
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
                Text("1 day").tag(1440)
                Text("Never").tag(0)
            }
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Toggle("Group PRs by worktree", isOn: $store.groupByWorktree)
            Toggle("Auto-expand active PRs", isOn: $store.autoExpandActivePRs)
            Text("When on, only PRs that are actively running or updated within the last 30 minutes open by default. Stays expanded until you collapse or quit the app.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Toggle("Resume prompt on wake", isOn: $store.resumePromptOnWake)
        }
    }

    #if DEBUG
    private var developerSection: some View {
        Section("Developer") {
            Toggle("Show demo data", isOn: $store.showDemoData)
            Text("Replaces live polling with fixture PRs. Useful for previewing the UI when no PRs are active.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
    #endif

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
