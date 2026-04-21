import Foundation

/// Subscribes the GUI to the `shipyard daemon` subprocess for live
/// webhook events.
///
/// Replaces the Swift webhook server / tunnel controller / registrar
/// that used to live in this module — all of that logic now runs in
/// the shipyard CLI (see shipyard#125). The GUI's responsibility
/// shrinks to:
///
///   * Decide whether to launch the daemon (reads `LiveUpdateMode` +
///     `TailscaleProbe` — same state machine as before).
///   * Spawn `shipyard daemon start` as a subprocess when going live.
///   * Open the daemon's Unix socket, subscribe, read NDJSON events,
///     dispatch to `AppStore.apply(webhookEvent:)`.
///   * Periodically read daemon status for UI rendering.
///   * On Live → Off, send `{"type":"stop"}` to the daemon.
///
/// User-visible behavior is identical to the prior in-process impl.
@MainActor
final class DaemonClient {

    // Observable bits the AppStore mirrors to the UI.
    private(set) var status: LiveUpdateStatus = .polling(reason: .userDisabled)
    var onStatusChange: ((LiveUpdateStatus) -> Void)?
    var onEvent: ((WebhookEvent) -> Void)?

    private var activeSession: Session?
    private var lastEventAt: Date?
    private var cachedStatus: DaemonStatus?

    /// Drive the client to a new state based on user prefs + Tailscale
    /// readiness. Called after mode toggles, Tailscale state changes,
    /// foreground events.
    func reconcile(
        mode: LiveUpdateMode,
        tailscale: TailscaleStatus,
        repos: Set<String>
    ) async {
        let (attemptLive, reason) = Self.decide(mode: mode, tailscale: tailscale)

        if !attemptLive {
            await tearDown()
            update(status: .polling(reason: reason))
            return
        }

        guard let shipyardBinary = Self.resolveShipyardBinary() else {
            await tearDown()
            update(status: .polling(reason: .daemonUnavailable(
                "shipyard CLI not found on PATH; install shipyard to enable live mode"
            )))
            return
        }

        if activeSession == nil {
            let session = Session(shipyardBinary: shipyardBinary, repos: repos)
            session.onEvent = { [weak self] event in
                Task { @MainActor in self?.recordDelivery(event: event) }
            }
            session.onStatus = { [weak self] status in
                Task { @MainActor in self?.apply(daemonStatus: status) }
            }
            session.onDisconnect = { [weak self] reason in
                Task { @MainActor in self?.handleDisconnect(reason: reason) }
            }
            activeSession = session
            await session.start()
        }

        // While the daemon is connecting/polling we show a transient
        // "live (waiting for first event)" state backed by cached URL;
        // once the daemon reports status this gets rewritten.
        if case .live = status {
            // already live — keep as-is
        } else if let s = cachedStatus, let url = s.tunnelURL {
            update(status: .live(tunnelURL: url, lastEventAt: lastEventAt))
        } else {
            update(status: .polling(reason: nil)) // transitional
        }
    }

    /// Pure-function decision table; same matrix as the old
    /// LiveModeController so the GUI's Auto/On/Off semantics don't
    /// shift in the migration.
    nonisolated static func decide(
        mode: LiveUpdateMode,
        tailscale: TailscaleStatus
    ) -> (attemptLive: Bool, reason: LiveUpdateStatus.PollingReason?) {
        switch mode {
        case .off:
            return (false, .userDisabled)
        case .auto, .on:
            if tailscale.isReady { return (true, nil) }
            if tailscale.binaryPath == nil { return (false, .tailscaleNotInstalled) }
            if tailscale.backendState != "Running" { return (false, .tailscaleNotRunning) }
            if !tailscale.funnelPermitted { return (false, .funnelNotPermitted) }
            return (false, .tailscaleNotRunning)
        }
    }

    /// Called when a disclosure-worthy state change happens that the
    /// AppStore needs to react to. Kept public for the AppStore's
    /// reseed hooks (matches LiveModeController's old API shape).
    func recordDelivery(event: WebhookEvent, at date: Date = Date()) {
        lastEventAt = date
        onEvent?(event)
        if case .live(let url, _) = status {
            update(status: .live(tunnelURL: url, lastEventAt: date))
        } else if let url = cachedStatus?.tunnelURL {
            update(status: .live(tunnelURL: url, lastEventAt: date))
        }
    }

    // MARK: - Internals

    private func apply(daemonStatus: DaemonStatus) {
        cachedStatus = daemonStatus
        if let url = daemonStatus.tunnelURL {
            update(status: .live(tunnelURL: url, lastEventAt: lastEventAt))
        } else {
            update(status: .polling(reason: .tunnelStartFailed(
                daemonStatus.lastError ?? "daemon reported no tunnel"
            )))
        }
    }

    private func handleDisconnect(reason: String) {
        activeSession = nil
        // "daemon socket not available at X" / "daemon socket closed" /
        // "daemon exited" are all daemon-process-lifecycle failures,
        // not Tailscale Funnel failures. Attribute accordingly so the
        // Settings banner doesn't blame Tailscale for a CLI install
        // / spawn bug.
        update(status: .polling(reason: .daemonUnavailable(reason)))
    }

    private func tearDown() async {
        if let session = activeSession {
            activeSession = nil
            await session.stop()
        }
    }

    private func update(status newStatus: LiveUpdateStatus) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }

    private static func resolveShipyardBinary() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.pulp/bin/shipyard",
            "/usr/local/bin/shipyard",
            "/opt/homebrew/bin/shipyard",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Socket path

    /// Mirrors shipyard's `Config.state_dir` on macOS:
    /// `~/Library/Application Support/shipyard/daemon/daemon.sock`.
    static func socketPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Application Support/shipyard/daemon/daemon.sock"
        )
    }
}

// MARK: - Session: owns one daemon-spawn + socket connection

@MainActor
private final class Session {
    var onEvent: ((WebhookEvent) -> Void)?
    var onStatus: ((DaemonStatus) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private let shipyardBinary: String
    private let repos: Set<String>
    private var readerTask: Task<Void, Never>?
    private var connection: DaemonConnection?

    init(shipyardBinary: String, repos: Set<String>) {
        self.shipyardBinary = shipyardBinary
        self.repos = repos
    }

    func start() async {
        await ensureDaemonRunning()
        await connectSocket()
    }

    func stop() async {
        // Ask the daemon to shut down if we own it. Safe no-op when
        // another subscriber is still connected — daemon side reaps
        // only when it has no subscribers.
        if let conn = connection {
            await conn.sendStopRequest()
        }
        readerTask?.cancel()
        readerTask = nil
        connection?.close()
        connection = nil
    }

    private func ensureDaemonRunning() async {
        var args = ["daemon", "start"]
        for repo in repos {
            args.append("--repo")
            args.append(repo)
        }
        _ = await runShipyard(args: args, timeout: 8)
    }

    private func connectSocket() async {
        // Retry a few times — the daemon takes a moment to bind the
        // socket after we spawn it, especially on first run when
        // Tailscale Funnel + webhook registration are warming up.
        let path = DaemonClient.socketPath()
        var connected: DaemonConnection? = nil
        for attempt in 1...10 {
            if let c = DaemonConnection.open(path: path) {
                connected = c
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(300_000_000 * attempt))
        }
        guard let conn = connected else {
            onDisconnect?("daemon socket not available at \(path)")
            return
        }
        connection = conn
        conn.sendSubscribe()
        conn.sendStatusRequest()
        readerTask = Task.detached { [weak self] in
            await self?.readLoop(conn: conn)
        }
    }

    nonisolated private func readLoop(conn: DaemonConnection) async {
        while !Task.isCancelled {
            guard let line = conn.readLine() else {
                await MainActor.run { self.onDisconnect?("daemon socket closed") }
                return
            }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = obj["type"] as? String
            switch type {
            case "hello":
                break
            case "event":
                if let event = DaemonWireDecoder.decodeEvent(obj) {
                    await MainActor.run { self.onEvent?(event) }
                }
            case "status":
                let status = DaemonWireDecoder.decodeStatus(obj)
                await MainActor.run { self.onStatus?(status) }
            case "goodbye":
                await MainActor.run { self.onDisconnect?("daemon exited") }
                return
            default:
                continue
            }
        }
    }

    private func runShipyard(args: [String], timeout: TimeInterval) async -> (Int32, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shipyardBinary)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                cont.resume(returning: (127, "failed to exec: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (
                    process.terminationStatus,
                    String(data: data, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}

// MARK: - Daemon IPC connection (blocking Unix socket)

final class DaemonConnection: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()
    private let lock = NSLock()

    private init(fd: Int32) { self.fd = fd }

    static func open(path: String) -> DaemonConnection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        // sun_path is a tuple of 104 Int8s on macOS; copy bytes in.
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            Darwin.close(fd)
            return nil
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { cStr in
                for (i, byte) in pathBytes.enumerated() {
                    cStr[i] = CChar(bitPattern: byte)
                }
                cStr[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, addrLen)
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        return DaemonConnection(fd: fd)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd) }
    }

    func sendSubscribe() {
        writeLine("{\"type\":\"subscribe\"}")
    }

    func sendStatusRequest() {
        writeLine("{\"type\":\"status\"}")
    }

    func sendStopRequest() async {
        writeLine("{\"type\":\"stop\"}")
    }

    private func writeLine(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        data.withUnsafeBytes { bytes in
            _ = Darwin.write(fd, bytes.baseAddress, data.count)
        }
    }

    /// Blocking readline — called from a detached task, not main.
    func readLine() -> String? {
        while true {
            if let newlineIdx = buffer.firstIndex(of: 0x0a) {
                let line = buffer[..<newlineIdx]
                buffer = buffer[(newlineIdx + 1)...]
                return String(data: line, encoding: .utf8) ?? ""
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

// MARK: - Wire format decoder (daemon NDJSON → WebhookEvent)

enum DaemonWireDecoder {
    static func decodeEvent(_ obj: [String: Any]) -> WebhookEvent? {
        guard let kind = obj["kind"] as? String else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        switch kind {
        case "workflow_run":
            return decodeWorkflowRun(payload)
        case "workflow_job":
            return decodeWorkflowJob(payload)
        case "pull_request":
            return decodePullRequest(payload)
        case "unhandled":
            return .unhandled(type: (obj["type"] as? String) ?? "unhandled")
        default:
            return nil
        }
    }

    static func decodeStatus(_ obj: [String: Any]) -> DaemonStatus {
        let tunnel = obj["tunnel"] as? [String: Any] ?? [:]
        let urlString = tunnel["url"] as? String
        let url = urlString.flatMap { URL(string: $0) }
        let repos = (obj["registered_repos"] as? [String]) ?? []
        let subs = (obj["subscribers"] as? Int) ?? 0
        let backend = (tunnel["backend"] as? String) ?? "tailscale"
        return DaemonStatus(
            tunnelBackend: backend,
            tunnelURL: url,
            subscribers: subs,
            registeredRepos: repos,
            lastError: nil
        )
    }

    private static func decodeWorkflowRun(_ p: [String: Any]) -> WebhookEvent? {
        guard let runId = p["run_id"] as? Int64 ?? (p["run_id"] as? Int).map(Int64.init) else {
            return nil
        }
        let payload = WebhookEvent.WorkflowRunPayload(
            action: (p["action"] as? String) ?? "",
            runId: runId,
            repo: (p["repo"] as? String) ?? "",
            headBranch: (p["head_branch"] as? String) ?? "",
            headSha: (p["head_sha"] as? String) ?? "",
            status: (p["status"] as? String) ?? "",
            conclusion: p["conclusion"] as? String,
            workflowName: (p["workflow_name"] as? String) ?? "",
            htmlURL: p["html_url"] as? String
        )
        return .workflowRun(payload)
    }

    private static func decodeWorkflowJob(_ p: [String: Any]) -> WebhookEvent? {
        guard let runId = p["run_id"] as? Int64 ?? (p["run_id"] as? Int).map(Int64.init),
              let jobId = p["job_id"] as? Int64 ?? (p["job_id"] as? Int).map(Int64.init)
        else { return nil }
        let payload = WebhookEvent.WorkflowJobPayload(
            action: (p["action"] as? String) ?? "",
            runId: runId,
            jobId: jobId,
            repo: (p["repo"] as? String) ?? "",
            name: (p["name"] as? String) ?? "",
            status: (p["status"] as? String) ?? "",
            conclusion: p["conclusion"] as? String,
            runnerName: p["runner_name"] as? String,
            labels: (p["labels"] as? [String]) ?? []
        )
        return .workflowJob(payload)
    }

    private static func decodePullRequest(_ p: [String: Any]) -> WebhookEvent? {
        guard let number = p["number"] as? Int else { return nil }
        let payload = WebhookEvent.PullRequestPayload(
            action: (p["action"] as? String) ?? "",
            number: number,
            repo: (p["repo"] as? String) ?? "",
            state: (p["state"] as? String) ?? "",
            merged: (p["merged"] as? Bool) ?? false,
            mergedAt: p["merged_at"] as? String,
            closedAt: p["closed_at"] as? String
        )
        return .pullRequest(payload)
    }
}

struct DaemonStatus: Equatable {
    let tunnelBackend: String
    let tunnelURL: URL?
    let subscribers: Int
    let registeredRepos: [String]
    let lastError: String?
}
