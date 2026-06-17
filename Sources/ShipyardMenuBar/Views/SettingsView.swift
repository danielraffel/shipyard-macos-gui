import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            generalSection
            serveSection
            smokeSection
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

    // MARK: - Serve CI builds from this Mac

    private var serveSection: some View {
        Section("Serve CI builds from this Mac") {
            // Discovery only returns lanes whose agent plist exists, so a discovered
            // lane IS installed — use the list directly rather than re-filtering on the
            // async status dict (which is .unknown on first paint and would briefly
            // flash the "no runner" empty state on a host that actually has runners).
            let installed = store.servingLanes
            if installed.isEmpty {
                Text("No CI runner is set up on this Mac yet. Once this machine is onboarded as a runner, a toggle appears here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                // Master row first when there's more than one lane, so you can
                // join/leave the whole pool in one tap without flipping each lane.
                if installed.count > 1 {
                    masterServeRow(installed)
                    Divider()
                }
                ForEach(installed) { lane in
                    serveRow(lane)
                }
                // Host-wide macOS VM cap (Apple allows 2 guests/Mac). Only relevant
                // when this Mac actually serves a macOS lane — derive from the list
                // already fetched above rather than re-scanning the filesystem.
                if installed.contains(where: { $0.platform.hasPrefix("macOS") }) {
                    Divider()
                    macosCapRow
                }
                Text("When on, this Mac joins the build pool and runs CI jobs in throwaway VMs. Turn it off while you're working so builds don't run on your machine.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { store.refreshServingStatus(); store.refreshMacOSVMCap() }
    }

    /// Host-wide cap on concurrent macOS VMs (1...2). Writes
    /// `~/.config/tartci/macos-vm-cap`, which the tartci runners read live.
    private var macosCapRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Max macOS VMs at once")
                    .font(.system(size: 12, weight: .medium))
                Text("Apple allows 2 per Mac. Set 1 to keep a slot free while you work.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { store.macosVMCap },
                set: { store.setMacOSVMCap($0) }
            )) {
                Text("1").tag(1)
                Text("2").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
        }
    }

    /// Master "serve everything" row — a single switch over all installed lanes.
    /// ON only when every lane is serving; from a mixed state the switch reads OFF,
    /// so one tap turns the whole pool on (then a second tap turns it all off).
    private func masterServeRow(_ lanes: [CIServingLane]) -> some View {
        let statuses = lanes.map { store.status(for: $0) }
        let anyToggling = statuses.contains { $0.isToggling }
        let allServing = !statuses.isEmpty && statuses.allSatisfy { $0.serving }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All lanes")
                    .font(.system(size: 12, weight: .semibold))
                Text(masterSummary(statuses))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if anyToggling {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: Binding(
                get: { allServing },
                set: { handleMasterToggle($0, lanes: lanes) }
            ))
            .labelsHidden()
            .disabled(anyToggling)
        }
    }

    private func masterSummary(_ statuses: [CIServingStatus]) -> String {
        if statuses.contains(where: { $0.isToggling }) { return "Updating…" }
        let serving = statuses.filter { $0.serving }.count
        if serving == 0 { return "All off" }
        let building = statuses.reduce(0) { $0 + $1.building }
        var s = serving == statuses.count
            ? "All \(statuses.count) serving"
            : "\(serving) of \(statuses.count) serving"
        if building > 0 { s += " · building \(building)" }
        return s
    }

    private func handleServeToggleAll(_ on: Bool, lanes: [CIServingLane]) {
        for lane in lanes { store.setServing(on, lane: lane) }
    }

    private func handleMasterToggle(_ on: Bool, lanes: [CIServingLane]) {
        guard !on else { handleServeToggleAll(true, lanes: lanes); return }
        // Turning the whole pool OFF — warn once if any lane has a build actually
        // running (busy runner), summing across lanes, before cancelling them all.
        let buildingLanes = lanes.map { store.status(for: $0) }.filter { $0.building > 0 }
        let n = buildingLanes.reduce(0) { $0 + $1.building }
        if n > 0 {
            let alert = NSAlert()
            alert.messageText = "Builds are running on this Mac"
            alert.informativeText =
                "Turning off all CI pool participation now will cancel \(n) in-progress "
                + "build\(n == 1 ? "" : "s") across \(buildingLanes.count) "
                + "lane\(buildingLanes.count == 1 ? "" : "s"). Stop anyway?"
            alert.addButton(withTitle: "Stop All")
            alert.addButton(withTitle: "Keep Serving")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        handleServeToggleAll(false, lanes: lanes)
    }

    private func serveRow(_ lane: CIServingLane) -> some View {
        let status = store.status(for: lane)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.platform)
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 5) {
                    Circle()
                        .fill(serveStatusColor(status))
                        .frame(width: 7, height: 7)
                    Text(status.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status.isToggling {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: Binding(
                get: { status.serving },
                set: { handleServeToggle($0, lane: lane, status: status) }
            ))
            .labelsHidden()
            .disabled(status.isToggling)
        }
    }

    private func serveStatusColor(_ status: CIServingStatus) -> Color {
        guard status.serving else { return .secondary }
        if status.building > 0 { return .green }   // a build is actually running
        if status.waiting > 0 { return .orange }   // serving, warm VM waiting for work
        return .secondary                          // serving, nothing up (idle)
    }

    // MARK: - Run local smoke checks (emulated x86_64)

    private var smokeSection: some View {
        Section("Run local smoke checks") {
            ForEach(store.smokeLanes) { lane in
                smokeRow(lane)
            }
            Text("On Apple Silicon the local VMs are ARM64. These run a one-shot x86_64 build via emulation (cross-compile + qemu-user) in a throwaway VM — a smoke/debug signal, not a gate. GitHub-hosted x64 stays authoritative.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .onAppear { store.refreshSmokeAvailability() }
    }

    private func smokeRow(_ lane: CISmokeLane) -> some View {
        let status = store.smokeStatus(for: lane)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.title)
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 5) {
                    Circle()
                        .fill(smokeStatusColor(status))
                        .frame(width: 7, height: 7)
                    Text(status.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status.isRunning {
                ProgressView().controlSize(.small)
            }
            Button("Run") { store.runSmoke(lane) }
                .controlSize(.small)
                .disabled(!status.canRun)
        }
    }

    private func smokeStatusColor(_ status: CISmokeStatus) -> Color {
        switch status.state {
        case .unavailable: return .secondary
        case .idle:        return .secondary
        case .running:     return .orange
        case .passed:      return .green
        case .failed:      return .red
        }
    }

    private func handleServeToggle(_ on: Bool, lane: CIServingLane, status: CIServingStatus) {
        // Only warn about cancelling a build when one is REALLY running (a busy
        // runner), not when the lane is merely serving a warm/idle VM — and name
        // the platform so it's clear which lane you're stopping.
        if !on && status.building > 0 {
            let n = status.building
            let alert = NSAlert()
            alert.messageText = "A \(lane.platform) build is running on this Mac"
            alert.informativeText =
                "Turning off \(lane.platform) pool participation now will cancel "
                + "\(n) in-progress \(lane.platform) build\(n == 1 ? "" : "s"). Stop anyway?"
            alert.addButton(withTitle: "Stop Now")
            alert.addButton(withTitle: "Keep Serving")
            if alert.runModal() == .alertFirstButtonReturn {
                store.setServing(false, lane: lane)
            }
            // Otherwise leave it serving; the toggle reverts on next refresh.
        } else {
            // Idle / waiting / turning on → no destructive prompt; a warm VM
            // waiting for work isn't an in-progress build.
            store.setServing(on, lane: lane)
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
