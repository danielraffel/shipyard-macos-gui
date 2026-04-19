import SwiftUI

/// Two-step inline flow: pick a target name (free-text since the list
/// of valid targets comes from the ship's .shipyard/config.toml, which
/// we don't parse today), then pick the provider. Runs
/// `shipyard cloud add-lane --pr N --target T [--provider P] --apply`.
struct AddLaneView: View {
    let ship: Ship
    let onDismiss: () -> Void
    @EnvironmentObject var store: AppStore

    @State private var targetName: String = ""
    @State private var stagedProvider: RunnerProvider?
    @State private var running: Bool = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let msg = resultMessage {
                resultBanner(msg)
            } else if let provider = stagedProvider {
                confirmation(provider: provider)
            } else if targetName.isEmpty {
                targetStep
            } else {
                providerStep
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

    private var targetStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title: "Add lane — target name")
            TextField("e.g. Windows-x86_64", text: $targetName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit {
                    if !targetName.isEmpty {
                        // proceed to provider step
                    }
                }
            Text("Must match a target defined in the worktree's .shipyard/config.toml.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title: "Pick provider for \(targetName)")
            ForEach(RunnerProvider.allCases, id: \.self) { provider in
                Button {
                    stagedProvider = provider
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
            Button("Back") { targetName = "" }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func confirmation(provider: RunnerProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title: "Add lane")
            Text("Add \(targetName) on \(provider.rawValue) to PR #\(ship.prNumber)?")
                .font(.system(size: 11))
            HStack {
                Button("Cancel") { stagedProvider = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await perform(provider) }
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
        }
    }

    @MainActor
    private func perform(_ provider: RunnerProvider) async {
        running = true
        defer { running = false }
        guard let binary = store.cliBinaryResolved else {
            resultMessage = "CLI not available."
            return
        }
        let out = await runShipyardCapturingStdout(binary: binary, args: [
            "cloud", "add-lane",
            "--pr", "\(ship.prNumber)",
            "--target", targetName,
            "--provider", provider.rawValue,
            "--apply",
        ])
        resultMessage = out.contains("error") || out.contains("Error")
            ? "Add-lane refused (see CLI)."
            : "Lane dispatched: \(targetName) on \(provider.rawValue)."
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        onDismiss()
    }
}
