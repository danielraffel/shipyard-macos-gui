import SwiftUI
import AppKit

/// One row for a GitHub Actions run. Used in two contexts:
///   * Nested inside a ship card (compact: true) to show runs for
///     that PR's head_sha / branch.
///   * Standalone in the "Other GitHub Actions runs" section
///     (compact: false).
/// Hover reveals cancel (for in-progress) or rerun (for failures).
struct GitHubRunRow: View {
    let run: GitHubRun
    var compact: Bool = false
    @EnvironmentObject var store: AppStore
    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(run.workflowName)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !compact && !run.headBranch.isEmpty {
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
            // Reserve constant space for action buttons to prevent
            // layout shift when hovering.
            HStack(spacing: 6) {
                if hovering {
                    actionButtons
                }
            }
            .frame(minWidth: 32, alignment: .trailing)
            Button {
                if let url = run.url { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Open on github.com")
        }
        .padding(.vertical, compact ? 2 : 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if run.isRunning {
            Button {
                store.cancelGitHubRun(run)
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(ShipyardColors.red)
            }
            .buttonStyle(.plain)
            .help("Cancel this run (`gh run cancel \(run.id)`)")
        } else if run.isFailure {
            Button {
                store.rerunGitHubRun(run)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(ShipyardColors.blue)
            }
            .buttonStyle(.plain)
            .help("Rerun failed jobs (`gh run rerun \(run.id)`)")
        }
    }

    private var statusIcon: some View {
        let (color, symbol): (Color, String) = {
            if run.isRunning { return (ShipyardColors.blue, "circle.fill") }
            if run.isFailure { return (ShipyardColors.red, "xmark.circle.fill") }
            if run.conclusion == "success" { return (ShipyardColors.green, "checkmark.circle.fill") }
            return (.secondary, "minus.circle.fill")
        }()
        return Image(systemName: symbol)
            .foregroundStyle(color)
            .font(.system(size: compact ? 10 : 11))
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
