import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case runners = "Runners"
    case doctor = "Doctor"
    case settings = "Settings"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .runners: return "figure.run"
        case .doctor: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab: PopoverTab = .runners

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.3)
            Group {
                switch tab {
                case .runners: ShipsView()
                case .doctor: DoctorView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // NOTE: No explicit background here. NSPopover supplies its
        // own material behind the content, and critically draws its
        // callout arrow with that SAME material. Adding .background
        // here (previously `.regularMaterial`) painted SwiftUI's own
        // material over the popover's — different enough in light
        // mode that the arrow looked like a mismatched lighter patch
        // at the top edge. Letting the native material show through
        // keeps content + arrow visually identical.
        .overlay(alignment: .bottom) {
            ClipboardToastView()
                .padding(.bottom, 14)
        }
    }

    private var headerBar: some View {
        VStack(spacing: 0) {
            // Top strip: brand + status dot + quit
            HStack(spacing: 6) {
                Image(systemName: "anchor")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Shipyard")
                    .font(.system(size: 13, weight: .semibold))
                statusDot
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit Shipyard (⌘Q)")
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Tab row — keep font weight constant so selection doesn't
            // re-flow the text width and shift the pill horizontally.
            HStack(spacing: 4) {
                ForEach(PopoverTab.allCases) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                    } label: {
                        Label(t.rawValue, systemImage: t.systemImage)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(tab == t ? Color.primary.opacity(0.08) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Show \(t.rawValue)")
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    /// Header status reflects **connection/service state**, not the roll-up
    /// of every tracked PR's CI outcome. Per-PR outcomes are already visible
    /// on each card and summarized in the "X green · Y failed" counter row.
    /// Rolling CI failures into the header read as service-level failure
    /// ("Shipyard · failed") which was misleading.
    @ViewBuilder
    private var statusDot: some View {
        let (color, label): (Color, String) = {
            if store.cliBinaryResolved == nil {
                return (ShipyardColors.red, "CLI not found")
            }
            switch store.liveStatus {
            case .live:
                return (ShipyardColors.green, "live")
            case .polling(let reason):
                if reason == .userDisabled {
                    return (.secondary, "polling (manual)")
                }
                return (.secondary, "polling")
            }
        }()
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
