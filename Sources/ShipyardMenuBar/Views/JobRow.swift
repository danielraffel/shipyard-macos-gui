import SwiftUI

/// One matrix-job row beneath a workflow. Shows status icon, job name,
/// runner provider pill, and (when a ship is in scope) a retarget
/// hover action that calls `shipyard cloud retarget` for that job's
/// target.
struct JobRow: View {
    let job: GitHubJob
    let ship: Ship?
    let iconResolver: (GitHubJob) -> (Color, String)
    let providerColor: (String) -> Color
    let onRetarget: (() -> Void)?
    let isRetargeting: Bool
    let onDismissRetarget: () -> Void

    @State private var hovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let (color, symbol) = iconResolver(job)
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .font(.system(size: 9))
                // Job name — click opens retarget (matches prototype
                // where tapping the build name is the retarget entry
                // point).
                Button {
                    onRetarget?()
                } label: {
                    Text(job.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .disabled(onRetarget == nil)
                .help(onRetarget == nil
                      ? "\(job.name) — \(job.runnerLabel)"
                      : "Tap to retarget this job to a different runner")
                Spacer(minLength: 4)
                // Provider pill is ALSO a retarget affordance — click
                // opens the same picker, mirrors the prototype.
                if job.provider != "unknown" {
                    Button {
                        onRetarget?()
                    } label: {
                        Text(job.provider)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(providerColor(job.provider))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(providerColor(job.provider).opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(onRetarget == nil)
                    .help(onRetarget == nil
                          ? "Ran on \(job.runnerLabel)"
                          : "Currently on \(job.provider) — tap to retarget")
                }
            }
            .padding(.vertical, 1)
            .onHover { hovering = $0 }

            if isRetargeting, let ship {
                JobRetargetPicker(
                    job: job,
                    ship: ship,
                    onDismiss: onDismissRetarget
                )
            }
        }
    }
}

/// Inline provider picker for retargeting a GitHub Actions matrix job.
/// Derives a shipyard target name from the job name (stripping the
/// trailing `[provider]` hint that pulp's workflows include), lets
/// the user pick a provider, and runs:
///
///   shipyard cloud retarget --pr N --target T --provider P --apply
///
/// The CLI is authoritative — if the derived target name doesn't
/// match anything in the PR's ship-state, it'll return an error
/// which we surface to the user.
struct JobRetargetPicker: View {
    let job: GitHubJob
    let ship: Ship
    let onDismiss: () -> Void
    @EnvironmentObject var store: AppStore

    @State private var running: Bool = false
    @State private var resultMessage: String?
    @State private var targetOverride: String?

    private var derivedTarget: String {
        // pulp convention: "Windows (x64) [namespace]" → "Windows (x64)"
        if let br = job.name.range(of: " [") {
            return String(job.name[..<br.lowerBound])
        }
        return job.name
    }

    private var effectiveTarget: String {
        targetOverride ?? derivedTarget
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let msg = resultMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                header
                targetHint
                providerList
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
        .padding(.leading, 18)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private var header: some View {
        HStack {
            Text("Retarget job")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private var targetHint: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("target:")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(effectiveTarget)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Text("Will run: shipyard cloud retarget --pr \(ship.prNumber) --target \"\(effectiveTarget)\" --provider <P> --apply")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RunnerProvider.allCases, id: \.self) { provider in
                Button {
                    Task { await perform(provider) }
                } label: {
                    HStack(spacing: 6) {
                        Text(provider.icon)
                            .font(.system(size: 10, weight: .bold))
                        Text(provider.rawValue)
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(provider.tint)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(provider.tint.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(running)
            }
        }
    }

    @MainActor
    private func perform(_ provider: RunnerProvider) async {
        running = true
        defer { running = false }
        let out = await store.retarget(
            ship: ship,
            target: Target(name: effectiveTarget),
            toProvider: provider
        )
        if out.contains("error") || out.contains("Error") || out.contains("no such target") {
            resultMessage = "Retarget refused: \(shortErr(out))"
        } else {
            resultMessage = "Dispatched → \(provider.rawValue). Next poll will show progress."
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        onDismiss()
    }

    private func shortErr(_ out: String) -> String {
        let line = out.split(separator: "\n").first.map(String.init) ?? out
        return String(line.prefix(80))
    }
}
