import SwiftUI
import AppKit

struct NamespaceActivitySection: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let instances = store.visibleNamespaceInstances()
        if !instances.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header(count: instances.count)
                currentDataNote
                VStack(spacing: 0) {
                    ForEach(instances) { instance in
                        NamespaceInstanceRow(instance: instance)
                        if instance != instances.last {
                            Divider().opacity(0.3)
                        }
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.background.opacity(0.35))
                )
            }
            .padding(.top, 4)
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 10))
                .foregroundStyle(ShipyardColors.orange)
            Text("NAMESPACE INSTANCES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("· \(count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            if let updated = store.namespaceActivityUpdatedAt {
                Text(relative(updated))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .help("Raw Namespace instances from nsc list. These are runner VMs, not PRs or GitHub job rows.")
    }

    private var currentDataNote: some View {
        Text("Active runner VMs from `nsc list` every 30s. `nsc` does not expose PR/job links, so these stay separate from Shipyard-tracked PRs.")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct NamespaceInstanceRow: View {
    @EnvironmentObject var store: AppStore
    let instance: NamespaceInstance
    @State private var expanded: Bool = false

    var body: some View {
        let jobContext = store.namespaceJobContext(for: instance)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
                if expanded && jobContext == nil {
                    store.fetchNamespaceDetailIfNeeded(for: instance)
                }
            } label: {
                summaryRow(jobContext: jobContext)
            }
            .buttonStyle(.plain)

            if expanded {
                detailPanel(jobContext: jobContext)
                    .padding(.leading, 24)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .help(helpText)
    }

    private func summaryRow(jobContext: NamespaceInstanceJobContext?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(instance.repo.isEmpty ? "unknown repo" : instance.repo)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    namespacePill(
                        instance.id,
                        foreground: .secondary,
                        background: Color.primary.opacity(0.055)
                    )
                }
                if let jobContext {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(jobContext.branch.isEmpty ? "unknown branch" : jobContext.branch)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(jobContext.shortSha)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 5) {
                    Text(instance.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    namespacePill(
                        instance.platformLabel,
                        foreground: platformStyle.foreground,
                        background: platformStyle.background
                    )
                    namespacePill(
                        instance.sizeLabel,
                        foreground: .primary,
                        background: Color.primary.opacity(0.06)
                    )
                    if let namespaceURL = jobContext?.namespaceURL {
                        Button {
                            NSWorkspace.shared.open(namespaceURL)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help(namespaceURL.absoluteString)
                    }
                }
            }
            Spacer(minLength: 6)
            Text(relative(instance.createdAt))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func namespacePill(
        _ label: String,
        foreground: Color,
        background: Color
    ) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
    }

    @ViewBuilder
    private func detailPanel(jobContext: NamespaceInstanceJobContext?) -> some View {
        if let jobContext {
            namespaceJobDetail(jobContext)
        } else if let detail = store.namespaceDetailsByInstanceID[instance.id] {
            namespaceDetail(detail)
        } else if let error = store.namespaceDetailErrorsByInstanceID[instance.id] {
            namespaceError(error)
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                Text("Loading `nsc describe` state...")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(6)
            .background(detailBackground)
        }
    }

    private func namespaceJobDetail(_ context: NamespaceInstanceJobContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(ShipyardColors.orange)
                Text("\(context.workflowName) — \(context.jobName)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(context.branch.isEmpty ? "unknown branch" : context.branch)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(context.shortSha)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                if let namespaceURL = context.namespaceURL {
                    linkButton("namespace", url: namespaceURL)
                }
                if let githubURL = context.githubURL {
                    linkButton("github job", url: githubURL)
                }
                commandButton("top", command: "nsc top \(instance.id)")
                commandButton("logs", command: "nsc logs \(instance.id) --limit 100")
            }
        }
        .padding(6)
        .background(detailBackground)
    }

    private func namespaceDetail(_ detail: NamespaceInstanceDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if detail.containers.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("No live details available; the instance may have exited.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(ShipyardColors.orange)
                    Text(detail.statusSummary)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(detail.containers) { container in
                    containerRow(container)
                }
            }
            commandButtons
        }
        .padding(6)
        .background(detailBackground)
    }

    private func namespaceError(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Retry") {
                    store.refreshNamespaceDetail(for: instance)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.blue)
                commandButtons
            }
        }
        .padding(6)
        .background(detailBackground)
    }

    private func containerRow(_ container: NamespaceContainerState) -> some View {
        HStack(spacing: 5) {
            Image(systemName: container.ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 8))
                .foregroundStyle(container.ready ? ShipyardColors.green : .secondary)
            Text(container.name)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(container.statusLabel)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var commandButtons: some View {
        HStack(spacing: 8) {
            commandButton("describe", command: "nsc describe \(instance.id) -o json")
            commandButton("top", command: "nsc top \(instance.id)")
            commandButton("logs", command: "nsc logs \(instance.id) --limit 100")
            if let url = URL(string: "https://cloud.namespace.so/") {
                linkButton("cloud", url: url)
            }
        }
    }

    private func linkButton(_ label: String, url: URL) -> some View {
        Button(label) {
            NSWorkspace.shared.open(url)
        }
        .buttonStyle(.plain)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.blue)
        .help(url.absoluteString)
    }

    private func commandButton(_ label: String, command: String) -> some View {
        Button(label) {
            ClipboardToast.shared.copy(command, label: "Copied command")
        }
        .buttonStyle(.plain)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.blue)
        .help(command)
    }

    private var detailBackground: some ShapeStyle {
        Color.primary.opacity(0.035)
    }

    private var platformStyle: (foreground: Color, background: Color) {
        switch instance.platformKey {
        case "windows":
            return (
                foreground: Color(red: 36/255, green: 92/255, blue: 62/255),
                background: Color(red: 213/255, green: 245/255, blue: 226/255)
            )
        case "macos":
            return (
                foreground: Color(red: 32/255, green: 74/255, blue: 96/255),
                background: Color(red: 221/255, green: 238/255, blue: 247/255)
            )
        case "linux":
            return (
                foreground: Color(red: 112/255, green: 82/255, blue: 0/255),
                background: Color(red: 250/255, green: 238/255, blue: 183/255)
            )
        default:
            return (
                foreground: ShipyardColors.orange,
                background: ShipyardColors.orange.opacity(0.14)
            )
        }
    }

    private var helpText: String {
        var parts = [
            instance.id,
            instance.shapeLabel,
            instance.profileTag ?? "",
            instance.ingressDomain ?? "",
        ]
        parts.removeAll(where: \.isEmpty)
        return parts.joined(separator: " - ")
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
