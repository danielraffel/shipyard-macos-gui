import SwiftUI
import AppKit

/// Global, short-lived "Copied ✓" toast. Used by Doctor rows and any
/// other place where we surface a one-click copy affordance.
@MainActor
final class ClipboardToast: ObservableObject {
    static let shared = ClipboardToast()
    @Published var message: String?

    func copy(_ text: String, label: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("\(label): \(preview(text))")
    }

    func showToast(_ msg: String) {
        message = msg
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if message == msg { message = nil }
        }
    }

    private func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(37)) + "…"
    }
}

struct ClipboardToastView: View {
    @ObservedObject var toast = ClipboardToast.shared

    var body: some View {
        if let message = toast.message {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard.fill")
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.75), in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.easeOut(duration: 0.2), value: message)
        }
    }
}
