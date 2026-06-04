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
        // The runner indicator lives in the always-visible header, so refresh
        // serving status when the popover opens (not only on the Settings tab).
        .onAppear { store.refreshServingStatus() }
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
                    .help("Live-data connection — how the app fetches PR status (live webhooks vs. polling). This is NOT your runner; builds still run when this says paused.")
                runnerDot
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
                            // Generous interior padding so the visible pill
                            // is large enough not to feel fiddly. 12/8 was
                            // 8/4 before — users reported mis-taps.
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(tab == t ? Color.primary.opacity(0.08) : .clear)
                            )
                            // contentShape extends the HIT region even when
                            // the visible pill is idle-transparent — clicks
                            // on whitespace inside the padded rect still
                            // register, not just on the glyph/text.
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Show \(t.rawValue)")
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
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
                if store.liveStartupPending {
                    return (.secondary, "starting live")
                }
                if reason == .userDisabled && store.liveUpdateMode == .off {
                    return (.secondary, "polling (manual)")
                }
                if let reason, reason.isWebhookScopeMissing {
                    return (.orange, reason.headerLabel)
                }
                if store.liveStatus.blocksGitHubAPIPolling {
                    return (.orange, reason?.headerLabel ?? "updates paused")
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

    /// The RUNNER signal — whether THIS Mac is serving CI builds — shown as a
    /// distinct indicator (a play/pause glyph, not a plain dot) so it never reads
    /// as the connection state next to it. Hidden when no runner lane is set up.
    @ViewBuilder
    private var runnerDot: some View {
        let state = store.runnerHeaderState
        if state.isVisible {
            let (icon, color): (String, Color) = {
                switch state.kind {
                case .serving: return ("play.circle.fill", ShipyardColors.green)
                case .off:     return ("pause.circle", .secondary)
                case .none:    return ("", .secondary)
                }
            }()
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(state.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .help("Runner state — whether this Mac is in the CI pool serving builds. Toggle in Settings → Serve CI builds from this Mac. A VM shown here may be a warm runner waiting for a job, not actively building.")
        }
    }
}
