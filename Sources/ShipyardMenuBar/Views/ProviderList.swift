import SwiftUI

/// Shared provider picker used by every retarget/add-lane flow so
/// they're visually identical. Each provider is a tinted capsule
/// row; the current provider (when passed in) gets a "current"
/// label and a subtle lock look.
struct ProviderList: View {
    /// If non-nil, the row matching this provider shows a "current"
    /// label and isn't tappable.
    let current: RunnerProvider?
    let onPick: (RunnerProvider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(RunnerProvider.allCases, id: \.self) { provider in
                let isCurrent = provider == current
                Button {
                    if !isCurrent { onPick(provider) }
                } label: {
                    HStack(spacing: 6) {
                        Text(provider.icon)
                            .font(.system(size: 10, weight: .bold))
                        Text(provider.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        if isCurrent {
                            Text("current")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(provider.tint)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(provider.tint.opacity(isCurrent ? 0.05 : 0.12))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isCurrent)
            }
        }
    }
}
