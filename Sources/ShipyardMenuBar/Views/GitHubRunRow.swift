import SwiftUI
import AppKit

/// One row for a GitHub Actions run. Used in two contexts:
///   * Nested inside a ship card (compact: true) to show runs for
///     that PR's head_sha / branch.
///   * Standalone in the "GitHub Actions" section below ship cards
///     (compact: false) for runs not associated with any ship.
struct GitHubRunRow: View {
    let run: GitHubRun
    var compact: Bool = false

    var body: some View {
        Button {
            if let url = run.url { NSWorkspace.shared.open(url) }
        } label: {
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
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, compact ? 2 : 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open run on github.com\n\(run.conclusion ?? run.status)")
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
