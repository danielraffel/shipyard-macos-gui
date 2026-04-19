import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case ships = "Ships"
    case doctor = "Doctor"
    case settings = "Settings"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .ships: return "shippingbox"
        case .doctor: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab: PopoverTab = .ships

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.3)
            Group {
                switch tab {
                case .ships: ShipsView()
                case .doctor: DoctorView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }

    private var headerBar: some View {
        HStack(spacing: 4) {
            ForEach(PopoverTab.allCases) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                } label: {
                    Label(t.rawValue, systemImage: t.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tab == t ? Color.primary.opacity(0.08) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Shipyard")
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
