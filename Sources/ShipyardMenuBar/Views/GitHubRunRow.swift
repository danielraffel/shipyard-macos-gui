import SwiftUI
import AppKit

/// One row for a GitHub Actions run. Used in two contexts:
///   * Nested inside a ship card (compact: true) — pass `ship` to
///     enable per-job retarget.
///   * Standalone in the "Other GitHub Actions runs" section
///     (compact: false, ship = nil) — retarget unavailable since
///     there's no PR context to pass to `shipyard cloud retarget`.
/// Hover reveals cancel (for in-progress) or rerun (for failures);
/// each matrix job also gets its own retarget action.
struct GitHubRunRow: View {
    let run: GitHubRun
    var compact: Bool = false
    var ship: Ship? = nil
    @EnvironmentObject var store: AppStore
    @State private var hovering: Bool = false
    @State private var retargetingJobId: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            workflowRow
            jobsList
        }
    }

    private var workflowRow: some View {
        HStack(spacing: 8) {
            statusIcon
            // The whole informational block is a button that opens
            // the run on github.com — much bigger tap target than the
            // tiny arrow icon.
            Button {
                if let url = run.url { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 8) {
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
                            providerPills
                        }
                        Text(relative(run.createdAt))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open on github.com — \(run.conclusion ?? run.status)")

            // Hover actions. Reserved width so row doesn't reshape.
            HStack(spacing: 6) {
                if hovering {
                    actionButtons
                }
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .opacity(0.5)
            }
            .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.vertical, compact ? 2 : 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { store.fetchJobsIfNeeded(for: run) }
    }

    /// If the workflow has a matrix of jobs (e.g. Build and Test →
    /// build-mac / build-linux / build-windows), render each job as
    /// an indented sub-row. Critical for answering "which platforms
    /// are running on namespace?" — those are matrix jobs, not
    /// separate workflow runs.
    @ViewBuilder
    private var jobsList: some View {
        let jobs = store.jobsByRunId[run.id] ?? []
        // Skip when there's zero or one job — the workflow row is
        // already the whole story. Only show when there's real matrix
        // information to reveal.
        if jobs.count > 1 {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(jobs, id: \.self) { job in
                    jobRow(job)
                }
            }
            .padding(.leading, 24) // indent under the workflow's status dot
        }
    }

    @ViewBuilder
    private func jobRow(_ job: GitHubJob) -> some View {
        JobRow(
            job: job,
            ship: ship,
            iconResolver: jobIcon,
            providerColor: providerColor,
            onRetarget: ship == nil ? nil : { retargetingJobId = job.databaseId },
            isRetargeting: retargetingJobId == job.databaseId,
            onDismissRetarget: { retargetingJobId = nil }
        )
    }

    private func jobIcon(_ job: GitHubJob) -> (Color, String) {
        switch (job.status, job.conclusion) {
        case ("completed", "success"): return (ShipyardColors.green, "checkmark.circle.fill")
        case ("completed", let c?) where c == "failure" || c == "timed_out": return (ShipyardColors.red, "xmark.circle.fill")
        case ("completed", "cancelled"): return (.secondary, "slash.circle.fill")
        case ("in_progress", _): return (ShipyardColors.blue, "circle.fill")
        case ("queued", _), ("waiting", _): return (.secondary, "circle.dashed")
        default: return (.secondary, "minus.circle.fill")
        }
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case "namespace": return ShipyardColors.orange
        case "github-hosted": return ShipyardColors.purple
        case "self-hosted": return ShipyardColors.blue
        default: return .secondary
        }
    }

    /// One small pill per distinct runner provider used by this run's
    /// jobs. Shows nothing while jobs are loading (don't bother the
    /// user with "…"). When loaded, hides "unknown" provider pills
    /// since they add noise without insight — if gh/labels didn't
    /// reveal what infra it ran on, the UI shouldn't pretend to know.
    @ViewBuilder
    private var providerPills: some View {
        if let providers = store.providers(for: run) {
            ForEach(providers.filter { $0 != "unknown" }, id: \.self) { provider in
                providerPill(for: provider)
            }
        }
    }

    private func providerPill(for provider: String) -> some View {
        let color: Color = {
            switch provider {
            case "namespace": return ShipyardColors.orange
            case "github-hosted": return ShipyardColors.purple
            case "self-hosted": return ShipyardColors.blue
            default: return .secondary
            }
        }()
        return Text(provider)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .help("Ran on \(provider)")
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
