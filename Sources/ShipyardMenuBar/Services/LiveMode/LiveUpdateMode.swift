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

    /// True when the GUI should avoid GitHub API polling because live
    /// mode needs one-time webhook authorization. Namespace polling is
    /// still safe because it uses `nsc`, not the GitHub API.
    var blocksGitHubAPIPolling: Bool {
        if case .polling(let reason) = self, reason?.isWebhookScopeMissing == true {
            return true
        }
        return false
    }

    /// Use the low reconciliation cadence when webhooks are active or
    /// when live mode is auth-blocked. The latter prevents a failed
    /// webhook registration from silently turning into 60s GitHub API
    /// polling.
    var usesConservativeGitHubPollingCadence: Bool {
        switch self {
        case .live:
            return true
        case .polling(let reason):
            return reason?.isWebhookScopeMissing == true
        }
    }

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

        static let webhookScopeCommand = "gh auth refresh -h github.com -s admin:repo_hook"

        var isWebhookScopeMissing: Bool {
            switch self {
            case .daemonUnavailable(let err),
                 .tunnelStartFailed(let err),
                 .serverStartFailed(let err):
                let lower = err.lowercased()
                return lower.contains("admin:repo_hook")
                    || lower.contains("repo_hook")
                    || lower.contains("webhook admin scope")
            default:
                return false
            }
        }

        var shouldWarn: Bool {
            if isWebhookScopeMissing { return true }
            switch self {
            case .userDisabled:
                return false
            default:
                return true
            }
        }

        var title: String {
            if isWebhookScopeMissing {
                return "Live webhook authorization needed"
            }
            switch self {
            case .userDisabled:
                return "Polling every 60s"
            default:
                return "Live updates unavailable — polling"
            }
        }

        var headerLabel: String {
            if isWebhookScopeMissing {
                return "hook auth"
            }
            return "polling"
        }

        var userFacing: String {
            if isWebhookScopeMissing {
                return "GitHub webhook management needs one-time authorization. GitHub API polling is paused to protect your rate limit; live webhooks will resume after granting the scope and restarting the daemon."
            }
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
