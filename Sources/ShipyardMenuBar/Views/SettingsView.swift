import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            generalSection
            cliSection
            routingSection
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
                return "Shipyard will open automatically after you restart your Mac."
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
            return "Near-realtime CI updates via webhooks when Tailscale Funnel is available. Pauses GitHub API polling when live mode is unavailable to protect your quota."
        case .on:
            return "Require near-realtime updates via Tailscale Funnel. Shows a warning and pauses GitHub API polling if live mode is unavailable."
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
                    if store.liveStartupPending {
                        Text("Live mode will connect after the menu has painted so the UI stays responsive.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if let reason {
                        Text(reason.userFacing)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if reason.isWebhookScopeMissing {
                            copyWebhookScopeCommand
                        }
                    }
                }
            }
        }
    }

    private var copyWebhookScopeCommand: some View {
        HStack(spacing: 6) {
            Text(LiveUpdateStatus.PollingReason.webhookScopeCommand)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                ClipboardToast.shared.copy(
                    LiveUpdateStatus.PollingReason.webhookScopeCommand,
                    label: "Copied command"
                )
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help("Copy GitHub auth command")
        }
        .padding(.top, 2)
    }

    private var pollingTitle: String {
        if store.liveStartupPending {
            return "Starting live updates"
        }
        if case .polling(let reason) = store.liveStatus,
           let reason,
           reason != .userDisabled {
            return reason.title
        }
        return "Polling every 60s"
    }

    private func pollingIcon(for reason: LiveUpdateStatus.PollingReason?) -> String {
        if store.liveStartupPending {
            return "dot.radiowaves.left.and.right"
        }
        if reason?.isWebhookScopeMissing == true {
            return "key.fill"
        }
        if store.liveUpdateMode == .on && reason != nil {
            return "exclamationmark.triangle.fill"
        }
        return "arrow.clockwise"
    }

    private func pollingTint(for reason: LiveUpdateStatus.PollingReason?) -> Color {
        if store.liveStartupPending {
            return .secondary
        }
        if reason?.isWebhookScopeMissing == true {
            return .orange
        }
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
            Toggle("Group PRs by worktree within repo", isOn: $store.groupByWorktree)
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

    // MARK: - Routing

    private var routingSection: some View {
        Section("Routing") {
            if store.cliBinaryResolved == nil {
                Text("Shipyard CLI not found — set it above to manage routing.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if store.routingRepositories.isEmpty {
                Text("No repos with Shipyard ship-state yet. Start a ship in a repo and it'll appear here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Picker("Repository", selection: Binding(
                    get: { store.selectedRoutingRepositoryID },
                    set: { store.selectedRoutingRepositoryID = $0
                        store.refreshSelectedRoutingProfiles() }
                )) {
                    ForEach(store.routingRepositories) { repo in
                        Text(repo.repo).tag(repo.id)
                    }
                }
                routingBody
            }
        }
        .onAppear { store.ensureRoutingSeeded() }
    }

    @ViewBuilder
    private var routingBody: some View {
        if let repo = store.selectedRoutingRepository {
            if repo.repoRoot == nil {
                Text("Choose this repo's checkout so Shipyard can read `.shipyard/config.toml`.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("Choose Checkout…") { chooseCheckout(for: repo) }
            } else {
                let state = store.routingStateByID[repo.id] ?? RoutingState()
                if state.isLoading && state.snapshot == nil {
                    Text("Loading routing profiles…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if let snapshot = state.snapshot {
                    if snapshot.profiles.isEmpty {
                        Text("This repo has no Shipyard profiles yet — define them in `.shipyard/config.toml`.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        routingDefaultRow(snapshot: snapshot)
                        ForEach(snapshot.profiles) { profile in
                            routingRow(profile, snapshot: snapshot, repoID: repo.id, state: state)
                        }
                        routingFooter(snapshot: snapshot)
                    }
                }
                if let error = state.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func routingRow(
        _ profile: RoutingProfile,
        snapshot: RoutingProfilesSnapshot,
        repoID: String,
        state: RoutingState
    ) -> some View {
        let isActive = snapshot.active == profile.name
        let writable = store.routingWriteSupported && !state.isSaving
        return Button {
            if writable && !isActive { store.useRoutingProfile(profile.name, for: repoID) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(profile.displayLabel)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(profile.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if !profile.targets.isEmpty {
                        Text(profile.targets.joined(separator: ", "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if state.isSaving && state.savingProfileName == profile.name {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!writable || isActive)
    }

    /// Explicit "no profile active" anchor so first-launch isn't an empty radio
    /// group. Selected when nothing is active; the repo then runs its default
    /// (unfiltered) targets. Not a switch target yet — reverting a per-machine
    /// override back to the repo default needs `config use --local --clear`.
    private func routingDefaultRow(snapshot: RoutingProfilesSnapshot) -> some View {
        let isActive = snapshot.active == nil
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("Repo default")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("default")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text("No per-machine profile — uses the repo's configured targets.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isActive ? 1 : 0.55)
        .help(isActive
            ? "No profile is active for this Mac."
            : "Reverting a local override to the repo default isn't supported yet.")
    }

    @ViewBuilder
    private func routingFooter(snapshot: RoutingProfilesSnapshot) -> some View {
        if !store.routingWriteSupported {
            Text("Update Shipyard to switch routing from here (`config use --local` not available).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if snapshot.activeSource == .local {
            Text("Local override active — stored per-machine in `.shipyard.local`. Won't change CI for collaborators.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else {
            Text("Using the repo default. Choosing an option saves a per-machine override (`.shipyard.local`); collaborators are unaffected.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func chooseCheckout(for repo: RoutingRepository) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if store.isValidRoutingCheckout(url.path) {
            store.setRoutingCheckoutPath(url.path, forRepo: repo.id)
        } else {
            let alert = NSAlert()
            alert.messageText = "Not a Shipyard checkout"
            alert.informativeText = "That folder doesn't contain `.shipyard/config.toml`."
            alert.runModal()
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
