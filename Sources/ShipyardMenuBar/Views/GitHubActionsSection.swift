import SwiftUI

/// Rendered below the ship cards. Lists recent GitHub Actions runs per
/// repo the app has seen ship-states for, scoped by the Settings →
/// "Time window" and "Hide workflows matching" filters.
struct GitHubActionsSection: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let groups = store.visibleGitHubRuns()
        if store.showGitHubActions && !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                ForEach(groups.keys.sorted(), id: \.self) { repo in
                    repoGroup(repo: repo, runs: groups[repo] ?? [])
                }
            }
            .padding(.top, 12)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("GitHub Actions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("last \(windowLabel)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var windowLabel: String {
        switch store.ghWindowMinutes {
        case 60: return "1h"
        case 240: return "4h"
        case 1440: return "1d"
        case 10080: return "7d"
        default: return "\(store.ghWindowMinutes)m"
        }
    }

    @ViewBuilder
    private func repoGroup(repo: String, runs: [GitHubRun]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repo)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            VStack(spacing: 0) {
                ForEach(runs) { run in
                    row(run)
                    if run != runs.last {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
    }

    @ViewBuilder
    private func row(_ run: GitHubRun) -> some View {
        Button {
            if let url = run.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                statusDot(for: run)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(run.workflowName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !run.headBranch.isEmpty {
                            Text("· \(run.headBranch)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(relative(run.createdAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open run on github.com\n\(run.conclusion ?? run.status)")
    }

    private func statusDot(for run: GitHubRun) -> some View {
        let (color, symbol): (Color, String) = {
            if run.isRunning { return (ShipyardColors.blue, "circle.fill") }
            if run.isFailure { return (ShipyardColors.red, "xmark.circle.fill") }
            if run.conclusion == "success" { return (ShipyardColors.green, "checkmark.circle.fill") }
            return (.secondary, "minus.circle.fill")
        }()
        return Image(systemName: symbol)
            .foregroundStyle(color)
            .font(.system(size: 11))
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
