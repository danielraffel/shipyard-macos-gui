import Foundation

/// User-facing live-updates preference. See Settings → Live updates.
///
/// - `auto` (default): enable webhook delivery via Tailscale Funnel
///   when it's available; pause GitHub API polling when it is not.
/// - `on`: require live mode. If Tailscale isn't available, show a
///   visible warning and pause GitHub API polling.
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
            return "Live when Tailscale Funnel is available; pause GitHub polling when it isn't."
        case .on:
            return "Require live updates via Tailscale Funnel; warn and pause GitHub polling when unavailable."
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

    /// True when the GUI should avoid GitHub API polling because the
    /// user asked for live mode but the app is not live. Namespace
    /// polling is still safe because it uses `nsc`, not the GitHub API.
    var blocksGitHubAPIPolling: Bool {
        switch self {
        case .live:
            return false
        case .polling(let reason):
            return reason != .userDisabled
        }
    }

    /// Use the low reconciliation cadence when webhooks are active or when
    /// live mode is blocked. The latter prevents a failed live setup from
    /// silently turning into 60s GitHub API polling.
    var usesConservativeGitHubPollingCadence: Bool {
        switch self {
        case .live:
            return true
        case .polling(let reason):
            return reason != .userDisabled
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
        /// GitHub authentication is failing — the daemon fell back to an
        /// invalid or rate-limited token (e.g. an ambient `gh` token at the
        /// anonymous 60/hr limit instead of the GitHub App token). Distinct
        /// from a tunnel/live-mode failure: the daemon is up, but live
        /// GitHub updates are degraded at the auth layer. The associated
        /// value is the daemon's human-readable diagnostic detail.
        case githubAuthDegraded(String)

        static let webhookScopeCommand = "gh auth refresh -h github.com -s admin:repo_hook"

        /// One-time command the user runs to repair a degraded GitHub token
        /// (import the GitHub App-token config instead of the anonymous
        /// ambient `gh` token).
        static let githubAuthDoctorCommand = "shipyard auth doctor"

        /// Wire discriminator the daemon uses to signal a GitHub auth
        /// failure as the pause cause. It travels inside the status frame's
        /// `last_error` string — mirroring how the webhook-scope hint
        /// travels — formatted as `github_auth_degraded: <detail>`.
        static let githubAuthDegradedWireCode = "github_auth_degraded"

        /// If `daemonError` carries the GitHub-auth-degraded discriminator,
        /// returns the human-readable detail (never empty); otherwise nil.
        /// The daemon-status mapper uses this to turn a `last_error` string
        /// into `.githubAuthDegraded`.
        static func githubAuthDegradedDetail(fromDaemonError daemonError: String) -> String? {
            let trimmed = daemonError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix(githubAuthDegradedWireCode) else {
                return nil
            }
            let remainder = trimmed.dropFirst(githubAuthDegradedWireCode.count)
            let detail = remainder.trimmingCharacters(
                in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines)
            )
            return detail.isEmpty ? "invalid or rate-limited GitHub token" : detail
        }

        var isGithubAuthDegraded: Bool {
            if case .githubAuthDegraded = self { return true }
            return false
        }

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
            case .githubAuthDegraded:
                return "GitHub authentication failing - GitHub polling paused"
            default:
                return "Live updates unavailable - GitHub polling paused"
            }
        }

        var headerLabel: String {
            if isWebhookScopeMissing {
                return "hook auth"
            }
            if isGithubAuthDegraded {
                return "auth failing"
            }
            if self != .userDisabled {
                return "paused"
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
                return "Install Tailscale to enable live updates. GitHub API polling is paused to protect your rate limit."
            case .tailscaleNotRunning:
                return "Tailscale isn't running. GitHub API polling is paused to protect your rate limit."
            case .funnelNotPermitted:
                return "Funnel isn't permitted on this tailnet. GitHub API polling is paused to protect your rate limit."
            case .daemonUnavailable(let err):
                return "shipyard daemon didn't start: \(err). "
                    + "Check ~/Library/Application Support/shipyard/daemon/daemon.log. "
                    + "GitHub API polling is paused to protect your rate limit."
            case .tunnelStartFailed(let err):
                return "Tailscale Funnel couldn't come up: \(err). GitHub API polling is paused to protect your rate limit."
            case .serverStartFailed(let err):
                return "Live mode setup failed: \(err). GitHub API polling is paused to protect your rate limit."
            case .githubAuthDegraded(let detail):
                return "GitHub auth is failing - Shipyard is using an invalid or "
                    + "rate-limited token (\(detail)). Run `\(Self.githubAuthDoctorCommand)` "
                    + "and import the App-token config. GitHub API polling is paused to "
                    + "protect your rate limit."
            }
        }
    }
}
