import SwiftUI

/// Inline picker that expands under a target row. Two states:
///  1. Provider list  — pick which provider to retarget to.
///  2. Confirmation — urgency depends on target.status (running → red,
///     otherwise blue).
struct RunnerPickerView: View {
    let target: Target
    let ship: Ship
    let onDismiss: () -> Void
    @EnvironmentObject var store: AppStore

    @State private var stagedProvider: RunnerProvider?
    @State private var running: Bool = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let provider = stagedProvider {
                confirmation(for: provider)
            } else if let msg = resultMessage {
                resultBanner(msg)
            } else {
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
        .padding(.leading, 22) // indent under the target row's status symbol
        // Expand out of the row: opacity fade only, no vertical slide,
        // so it doesn't look like it's falling from above its host row.
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Retarget \(target.name)")
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
            ForEach(RunnerProvider.allCases, id: \.self) { provider in
                let isCurrent = target.runner?.provider == provider
                Button {
                    if !isCurrent { stagedProvider = provider }
                } label: {
                    HStack(spacing: 6) {
                        Text(provider.icon)
                            .font(.system(size: 10, weight: .bold))
                        Text(provider.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        if isCurrent {
                            Text("current")
                                .font(.system(size: 9, weight: .regular))
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCurrent ? Color.gray.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isCurrent || running)
            }
        }
    }

    @ViewBuilder
    private func confirmation(for provider: RunnerProvider) -> some View {
        let isRunning = target.status == .running
        let isStale = target.isStale
        let warnTint: Color = isRunning ? .red : .blue
        VStack(alignment: .leading, spacing: 6) {
            if isRunning {
                Text("\u{26A0} This target is actively running\(isStale ? " (stale)" : ""). Retargeting will interrupt the current run.")
                    .font(.system(size: 11))
                    .foregroundStyle(warnTint)
            } else {
                Text("Move \(target.name) to \(provider.rawValue)?")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
            }
            HStack {
                Button("Cancel") { stagedProvider = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await perform(provider) }
                } label: {
                    Text(isRunning ? "Interrupt & Retarget" : "Retarget")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(warnTint, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(running)
            }
        }
    }

    private func resultBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    @MainActor
    private func perform(_ provider: RunnerProvider) async {
        running = true
        defer { running = false }
        let output = await store.retarget(ship: ship, target: target, toProvider: provider)
        // Short summary — if the CLI returned JSON, extract a readable hint.
        let short: String
        if output.contains("\"error\"") {
            short = "Retarget refused (see CLI output)."
        } else if output.isEmpty {
            short = "Retarget dispatched."
        } else {
            short = "Retarget dispatched → \(provider.rawValue)."
        }
        resultMessage = short
        stagedProvider = nil
        // Auto-close after a moment so the picker doesn't linger.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        onDismiss()
    }
}
