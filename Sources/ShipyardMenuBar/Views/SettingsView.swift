import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            cliSection
            githubSection
            notificationsSection
            autoClearSection
            displaySection
            developerSection
        }
        .formStyle(.grouped)
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
            Toggle("Resume prompt on wake", isOn: $store.resumePromptOnWake)
        }
    }

    private var developerSection: some View {
        Section("Developer") {
            Toggle("Show demo data", isOn: $store.showDemoData)
            Text("Replaces live ship-state polling with fixture ships. Useful for previewing the UI without active PRs.")
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
