import SwiftUI

struct DoctorView: View {
    @EnvironmentObject var store: AppStore
    @State private var checking: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if store.cliBinaryResolved == nil {
                    missingCLI
                } else if let result = store.doctorResult {
                    ForEach(result.sections) { section in
                        sectionView(section)
                    }
                } else {
                    ProgressView("Running doctor…")
                        .controlSize(.small)
                        .padding(.top, 20)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("What this checked")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text("Machine tools only — git, ssh, gh, nsc. Release-pipeline and per-repo checks (RELEASE_BOT_TOKEN, tag drift, governance) only appear when the CLI is invoked from inside a specific worktree. Run `shipyard doctor` in a terminal to see those for a given repo.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 10)
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack {
            if let result = store.doctorResult {
                HStack(spacing: 6) {
                    Circle()
                        .fill(result.ok ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(result.ok ? "Ready" : "Issues detected")
                        .font(.system(size: 13, weight: .semibold))
                }
            } else {
                Text("Doctor")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            if let last = store.lastDoctorCheckedAt {
                Text("checked \(relative(last))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task {
                    checking = true
                    await store.runDoctor()
                    checking = false
                }
            } label: {
                if checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("Re-check")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(checking || store.cliBinaryResolved == nil)
            .help("Run `shipyard doctor --json` again")
        }
    }

    private var missingCLI: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shipyard CLI not found")
                        .font(.system(size: 12, weight: .semibold))
                    Text("This app is a companion — it needs the Shipyard CLI installed separately.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            Link(destination: URL(string: "https://github.com/danielraffel/Shipyard#installation")!) {
                HStack(spacing: 4) {
                    Text("Install instructions")
                    Image(systemName: "arrow.up.forward.app")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: DoctorSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(section.entries) { entry in
                    entryRow(entry)
                    if entry != section.entries.last {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: DoctorEntry) -> some View {
        Button {
            var parts: [String] = [entry.name]
            if let v = entry.version { parts.append(v) }
            if let d = entry.detail { parts.append(d) }
            ClipboardToast.shared.copy(parts.joined(separator: "\n"), label: "Copied \(entry.name)")
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.ok ? .green : .red)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                    if let version = entry.version {
                        Text(version)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let detail = entry.detail, !entry.ok {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    }
                }
                Spacer()
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .opacity(0.7)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("Click to copy \(entry.name) details")
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
