import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            cliSection
            notificationsSection
            autoClearSection
            displaySection
            developerSection
        }
        .formStyle(.grouped)
    }

    private var cliSection: some View {
        Section("Shipyard CLI") {
            HStack {
                TextField(
                    "auto-detected",
                    text: Binding(
                        get: {
                            // Show the actual user-set path if any,
                            // otherwise the auto-resolved path so the
                            // field isn't visually empty while the app
                            // is clearly functional.
                            store.cliBinaryPath.isEmpty
                                ? (store.cliBinaryResolved ?? "")
                                : store.cliBinaryPath
                        },
                        set: { store.cliBinaryPath = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                Button("Browse…", action: browse)
                    .help("Open a file picker to locate the shipyard binary")
                Button("Resolve", action: store.resolveCLIBinary)
                    .help("Re-scan the default install paths")
            }
            if store.cliBinaryResolved != nil {
                Label("Auto-detected — override above to point elsewhere.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else if let err = store.cliBinaryError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                    Link("Install →",
                         destination: URL(string: "https://github.com/danielraffel/Shipyard#installation")!)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
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
