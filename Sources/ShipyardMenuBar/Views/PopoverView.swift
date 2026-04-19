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
        HStack(spacing: 12) {
            ForEach(PopoverTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    Label(t.rawValue, systemImage: t.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Color.primary : Color.secondary)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
