import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            cliSection
            notificationsSection
            autoClearSection
            displaySection
        }
        .formStyle(.grouped)
    }

    private var cliSection: some View {
        Section("Shipyard CLI") {
            HStack {
                TextField("Path to `shipyard` binary", text: $store.cliBinaryPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…", action: browse)
                Button("Resolve", action: store.resolveCLIBinary)
            }
            if let resolved = store.cliBinaryResolved {
                Text("✓ resolved: \(resolved)")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else if let err = store.cliBinaryError {
                HStack(spacing: 6) {
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
