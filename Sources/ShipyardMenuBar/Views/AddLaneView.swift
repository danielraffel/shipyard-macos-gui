import SwiftUI

/// Two-step inline flow for `shipyard cloud add-lane`:
///   1. Pick a target — grouped into "New targets" (known from other
///      ships, not yet on this one) and "Parallel runner" (already on
///      this ship, add a second runner for it). A fallback "Custom…"
///      option reveals a text field for ad-hoc targets.
///   2. Pick a provider for that target.
///   3. Confirm → run `shipyard cloud add-lane … --apply`.
struct AddLaneView: View {
    let ship: Ship
    let onDismiss: () -> Void
    @EnvironmentObject var store: AppStore

    private enum Step: Equatable {
        case pickTarget
        case customTarget
        case pickProvider(target: String)
        case confirm(target: String, provider: RunnerProvider)
        case result(message: String)
    }

    @State private var step: Step = .pickTarget
    @State private var customName: String = ""
    @State private var running: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch step {
            case .pickTarget: targetPicker
            case .customTarget: customTargetField
            case .pickProvider(let target): providerPicker(for: target)
            case .confirm(let target, let provider): confirmation(target: target, provider: provider)
            case .result(let msg): resultBanner(msg)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    // MARK: - Step 1: target

    /// Platforms already running on this ship — either via shipyard
    /// dispatch OR GitHub Actions. These appear as "Parallel runner
    /// on existing" rows (user wants to add a SECOND runner for an
    /// already-running platform) and are filtered out of "New
    /// targets" (can't add what's already there).
    private var existingTargets: [String] {
        store.currentPlatformNames(for: ship)
    }

    /// Candidates minus what's already represented. For a fully
    /// triple-platformed pulp PR, this will be empty — meaning the
    /// picker shows only "Parallel on existing" + Custom fallback.
    private var newTargets: [String] {
        let existing = Set(existingTargets)
        return store.candidateTargetNames(for: ship)
            .filter { !existing.contains($0) }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title: "Add lane — pick target")
            if !newTargets.isEmpty {
                ForEach(newTargets, id: \.self) { t in
                    targetRow(t, kind: .new)
                }
            } else {
                Text("Every known platform is already running on this PR. Use Retarget on a lane to switch its runner.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            Divider().opacity(0.3).padding(.vertical, 4)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { step = .customTarget }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                    Text("Custom target name…")
                }
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Type a target name not yet seen elsewhere")
        }
    }

    private enum TargetRowKind { case new }

    private func targetRow(_ name: String, kind: TargetRowKind) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                step = .pickProvider(target: name)
            }
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add \(name) to this PR")
    }

    private var customTargetField: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title: "Custom target name")
            TextField("e.g. Windows-x86_64", text: $customName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit(confirmCustomName)
            Text("Must match a target defined in the worktree's .shipyard/config.toml.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.15)) { step = .pickTarget }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    confirmCustomName()
                } label: {
                    Text("Next →")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(customName.isEmpty ? .gray.opacity(0.5) : ShipyardColors.blue, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(customName.isEmpty)
            }
        }
    }

    private func confirmCustomName() {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            step = .pickProvider(target: trimmed)
        }
    }

    // MARK: - Step 2: provider

    private func providerPicker(for target: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title: "Pick provider for \(target)")
            ForEach(RunnerProvider.allCases, id: \.self) { provider in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        step = .confirm(target: target, provider: provider)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(provider.icon)
                            .font(.system(size: 10, weight: .bold))
                        Text(provider.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .foregroundStyle(provider.tint)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(provider.tint.opacity(0.1))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button("Back") {
                withAnimation(.easeInOut(duration: 0.15)) { step = .pickTarget }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    // MARK: - Step 3: confirm

    private func confirmation(target: String, provider: RunnerProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title: "Add lane")
            Text(verbatim: "Dispatch \(target) on \(provider.rawValue) for PR #\(ship.prNumber)?")
                .font(.system(size: 11))
            HStack {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        step = .pickProvider(target: target)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await perform(target: target, provider: provider) }
                } label: {
                    Text("Add Lane")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ShipyardColors.blue, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(running)
            }
        }
    }

    // MARK: - Common chrome

    private func header(title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private func resultBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - CLI

    @MainActor
    private func perform(target: String, provider: RunnerProvider) async {
        running = true
        defer { running = false }
        guard let binary = store.cliBinaryResolved else {
            step = .result(message: "CLI not available.")
            return
        }
        let out = await runShipyardCapturingStdout(binary: binary, args: [
            "cloud", "add-lane",
            "--pr", "\(ship.prNumber)",
            "--target", target,
            "--provider", provider.rawValue,
            "--apply",
        ])
        let msg = (out.contains("error") || out.contains("Error"))
            ? "Add-lane refused (see CLI)."
            : "Lane dispatched: \(target) on \(provider.rawValue)."
        step = .result(message: msg)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        onDismiss()
    }
}
