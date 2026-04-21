import Foundation

/// Orchestrates the live-updates lifecycle:
///   mode preference + Tailscale probe → start/stop server, tunnel,
///   webhook registrations; report status back to AppStore.
///
/// Pure logic for resolving the mode decision lives in static helpers
/// so it's unit-testable without a subprocess.
@MainActor
final class LiveModeController {

    // Observable bits the AppStore mirrors back to the UI.
    private(set) var status: LiveUpdateStatus = .polling(reason: .userDisabled)
    var onStatusChange: ((LiveUpdateStatus) -> Void)?

    private var server: WebhookServer?
    private var boundPort: UInt16?
    private var tailscaleBinary: String?
    private var tunnelURL: URL?
    private var lastProbe: TailscaleStatus?
    private var registered: [String: Int64] = [:] // repo → hookId
    private var lastEventAt: Date?

    /// The decision table from issue #2. Pure function — `nonisolated`
    /// so unit tests (and any non-main-actor caller) can hit it without
    /// an `await`.
    ///
    /// - Parameters:
    ///   - mode: user preference (Auto/On/Off).
    ///   - tailscale: latest probe result.
    /// - Returns:
    ///   - `attemptLive` — whether we should try to stand up the tunnel.
    ///   - `reason` — polling reason to surface when we aren't going live.
    nonisolated static func decide(
        mode: LiveUpdateMode,
        tailscale: TailscaleStatus
    ) -> (attemptLive: Bool, reason: LiveUpdateStatus.PollingReason?) {
        switch mode {
        case .off:
            return (false, .userDisabled)
        case .auto:
            if tailscale.isReady { return (true, nil) }
            // Auto never punishes a user without Tailscale — it
            // stays silent and falls back to polling without a
            // visible warning. Reason is recorded for Settings.
            if tailscale.binaryPath == nil { return (false, .tailscaleNotInstalled) }
            if tailscale.backendState != "Running" { return (false, .tailscaleNotRunning) }
            if !tailscale.funnelPermitted { return (false, .funnelNotPermitted) }
            return (false, .tailscaleNotRunning)
        case .on:
            if tailscale.isReady { return (true, nil) }
            // On: same reason mapping as Auto, but the UI renders
            // these as a warning banner instead of a quiet hint.
            if tailscale.binaryPath == nil { return (false, .tailscaleNotInstalled) }
            if tailscale.backendState != "Running" { return (false, .tailscaleNotRunning) }
            if !tailscale.funnelPermitted { return (false, .funnelNotPermitted) }
            return (false, .tailscaleNotRunning)
        }
    }

    /// Drive the controller to a new state based on user prefs +
    /// the current Tailscale probe. Called after mode toggles,
    /// Tailscale state changes, foreground events.
    ///
    /// `repos` is the set of repo full names to keep webhooks on.
    /// `handleEvent` is the callback fired for each validated webhook.
    func reconcile(
        mode: LiveUpdateMode,
        tailscale: TailscaleStatus,
        repos: Set<String>,
        ghBinary: String?,
        handleEvent: @escaping (WebhookEvent) -> Void
    ) async {
        lastProbe = tailscale
        let (attemptLive, reason) = Self.decide(mode: mode, tailscale: tailscale)

        if !attemptLive {
            await tearDown()
            update(status: .polling(reason: reason))
            return
        }

        // Going live. Make sure server + tunnel are up, webhooks
        // are registered, then mirror "live" status.
        do {
            let port = try ensureServerRunning(handleEvent: handleEvent)
            if let binary = tailscale.binaryPath {
                try await TunnelController.start(binaryPath: binary, port: port)
                tailscaleBinary = binary
            }
            if let url = tailscale.funnelURL {
                tunnelURL = url
                if let gh = ghBinary {
                    await ensureHooksRegistered(repos: repos, url: url, ghBinary: gh)
                }
            }
            if let url = tunnelURL {
                update(status: .live(tunnelURL: url, lastEventAt: lastEventAt))
            } else {
                update(status: .polling(reason: .tunnelStartFailed("no Funnel URL")))
            }
        } catch let TunnelController.TunnelError.startFailed(msg) {
            await tearDown()
            update(status: .polling(reason: .tunnelStartFailed(msg)))
        } catch {
            await tearDown()
            update(status: .polling(reason: .serverStartFailed(error.localizedDescription)))
        }
    }

    /// Called from the WebhookServer handler after a valid delivery.
    func recordDelivery(at date: Date = Date()) {
        lastEventAt = date
        if case .live(let url, _) = status {
            update(status: .live(tunnelURL: url, lastEventAt: date))
        }
    }

    // MARK: - Internals

    private func ensureServerRunning(
        handleEvent: @escaping (WebhookEvent) -> Void
    ) throws -> UInt16 {
        if let port = boundPort, server != nil { return port }
        let secret = SecretStore.loadOrCreate(account: "shared") {
            WebhookSignature.generateSecret()
        }
        let server = WebhookServer { [weak self] headers, body in
            let sigHeader = headers["x-hub-signature-256"]
            guard WebhookSignature.isValid(
                body: body,
                secret: secret,
                header: sigHeader
            ) else {
                return .unauthorized
            }
            let eventHeader = headers["x-github-event"]
            if let event = WebhookEventDecoder.decode(
                eventHeader: eventHeader,
                body: body
            ) {
                DispatchQueue.main.async {
                    self?.recordDelivery()
                    handleEvent(event)
                }
            }
            return .ok
        }
        let port = try server.start()
        self.server = server
        self.boundPort = port
        return port
    }

    private func ensureHooksRegistered(
        repos: Set<String>,
        url: URL,
        ghBinary: String
    ) async {
        let secret = SecretStore.loadOrCreate(account: "shared") {
            WebhookSignature.generateSecret()
        }
        // The server routes `POST /webhook`; Tailscale Funnel hands
        // off bare hostname URLs, so explicitly append the path.
        let hookURL = url.appendingPathComponent("webhook")
        let key = "liveMode.lastRegisteredURL"
        let previousURL = UserDefaults.standard.string(forKey: key)
        let urlChanged = previousURL != hookURL.absoluteString

        for repo in repos {
            do {
                if let existingId = registered[repo] {
                    // Already registered. If the URL we'd use now
                    // differs from last time, patch the hook so it
                    // points at the right place.
                    if urlChanged {
                        try await WebhookRegistrar.update(
                            repo: repo,
                            hookId: existingId,
                            url: hookURL,
                            secret: secret,
                            ghBinary: ghBinary
                        )
                    }
                    continue
                }
                let id = try await WebhookRegistrar.create(
                    repo: repo, url: hookURL, secret: secret, ghBinary: ghBinary
                )
                registered[repo] = id
                persistRegistered()
            } catch {
                // Don't fail the whole reconcile — surface as a
                // status line later; other repos may still register.
                _ = error
            }
        }
        UserDefaults.standard.set(hookURL.absoluteString, forKey: key)
    }

    private func tearDown() async {
        if let binary = tailscaleBinary {
            try? await TunnelController.stop(binaryPath: binary)
        }
        server?.stop()
        server = nil
        boundPort = nil
        tunnelURL = nil
        tailscaleBinary = nil
        // Intentionally DO NOT unregister hooks here — we keep them
        // so a subsequent enable doesn't double-create. Hooks get
        // cleaned up explicitly by `unregisterAll`.
    }

    /// Called when the user flips mode to Off — scrub registered
    /// webhooks so GitHub stops delivering to a URL that won't answer.
    func unregisterAll(ghBinary: String) async {
        let snapshot = registered
        for (repo, id) in snapshot {
            try? await WebhookRegistrar.delete(
                repo: repo, hookId: id, ghBinary: ghBinary
            )
            registered.removeValue(forKey: repo)
        }
        persistRegistered()
    }

    // Persist registered hooks so we can tear down on next launch
    // even if an earlier run crashed before delete.
    private static let registeredKey = "liveMode.registeredHooks"

    private func persistRegistered() {
        let encoded = try? JSONEncoder().encode(registered.map {
            WebhookRegistrar.RegisteredHook(repo: $0.key, hookId: $0.value)
        })
        UserDefaults.standard.set(encoded, forKey: Self.registeredKey)
    }

    /// Restore persisted registrations at launch so we can tear
    /// them down even after a crash.
    func restorePersistedRegistrations() {
        guard let data = UserDefaults.standard.data(forKey: Self.registeredKey),
              let items = try? JSONDecoder().decode([WebhookRegistrar.RegisteredHook].self, from: data)
        else { return }
        registered = Dictionary(uniqueKeysWithValues: items.map { ($0.repo, $0.hookId) })
    }

    private func update(status newStatus: LiveUpdateStatus) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
