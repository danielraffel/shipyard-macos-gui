import Foundation

/// User-facing live-updates preference. See Settings → Live updates.
///
/// - `auto` (default): enable webhook delivery via Tailscale Funnel
///   when it's available; silently fall back to polling when it's not.
/// - `on`: require live mode. If Tailscale isn't available, show a
///   visible warning and poll as fallback.
/// - `off`: polling only, never attempt live mode.
enum LiveUpdateMode: String, CaseIterable, Identifiable {
    case auto
    case on
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .on:   return "On"
        case .off:  return "Off"
        }
    }

    /// One-line Settings hint under the picker.
    var hint: String {
        switch self {
        case .auto:
            return "Live when Tailscale Funnel is available, polling when it isn't."
        case .on:
            return "Require live updates via Tailscale Funnel; warn when unavailable."
        case .off:
            return "Polling only. Live updates disabled."
        }
    }
}

/// Resolved runtime state — what the app is actually doing right now
/// after reconciling the user's `LiveUpdateMode` with Tailscale
/// availability. Used to drive the Settings status line and any
/// banner/toast on state transitions.
enum LiveUpdateStatus: Equatable {
    /// Polling at the current cadence. `reason` is non-nil when the
    /// user asked for live (mode = on or auto) but it couldn't be
    /// started — surfaces as an advisory/warning.
    case polling(reason: PollingReason?)

    /// Live mode is running. `tunnelURL` is the Funnel URL GitHub
    /// webhooks are registered against; `lastEventAt` reflects the
    /// most recent successfully-validated delivery.
    case live(tunnelURL: URL, lastEventAt: Date?)

    enum PollingReason: Equatable {
        case userDisabled
        case tailscaleNotInstalled
        case tailscaleNotRunning
        case funnelNotPermitted
        /// Daemon process failed to spawn / exited before the IPC
        /// socket became reachable. Typically means the shipyard CLI
        /// install is outdated or broken; check daemon.log.
        case daemonUnavailable(String)
        /// The daemon started but its Tailscale Funnel backend
        /// couldn't bring up the public tunnel. (Reported via
        /// daemon status, not inferred from socket absence.)
        case tunnelStartFailed(String)
        /// Generic "daemon started but something internal failed"
        /// bucket. Used for cases we can't attribute more cleanly.
        case serverStartFailed(String)

        var userFacing: String {
            switch self {
            case .userDisabled:
                return "Live updates disabled."
            case .tailscaleNotInstalled:
                return "Install Tailscale to enable live updates."
            case .tailscaleNotRunning:
                return "Tailscale isn't running."
            case .funnelNotPermitted:
                return "Funnel isn't permitted on this tailnet."
            case .daemonUnavailable(let err):
                return "shipyard daemon didn't start: \(err). "
                    + "Check ~/Library/Application Support/shipyard/daemon/daemon.log. "
                    + "Often fixed by upgrading the shipyard CLI."
            case .tunnelStartFailed(let err):
                return "Tailscale Funnel couldn't come up: \(err)"
            case .serverStartFailed(let err):
                return "Live mode setup failed: \(err)"
            }
        }
    }
}
