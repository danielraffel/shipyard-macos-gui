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
        // Historical behavior gated `attemptLive` on our local
        // tailscale probe. The probe can fail inside a signed release
        // bundle for reasons that DON'T affect the daemon — e.g. the
        // Tailscale.app binary being in a location the GUI app can't
        // exec, subtle Process.run env differences, etc. Meanwhile
        // the daemon (which has its own probe using the right PATH)
        // might already have a live tunnel.
        //
        // Flip the gate: in Auto/On mode, always attempt to connect
        // to the daemon. If the daemon can't start (really missing
        // Tailscale, funnel permission denied, etc.) it exits with
        // code 3 and `ensureDaemonRunning` routes the real error
        // through `onDisconnect` → `.polling(reason: .daemonUnavailable(...))`.
        // That way the failure message reflects the daemon's
        // authoritative view, not the GUI's speculative probe.
        switch mode {
        case .off:
            return (false, .userDisabled)
        case .auto, .on:
            return (true, nil)
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
        // First: honor the user's explicit override from Settings. This
        // mirrors AppStore.resolveCLIBinary()'s first branch so that a
        // custom path set in Settings is respected by the daemon spawn
        // too (the two lookups were accidentally divergent prior).
        let override = UserDefaults.standard.string(forKey: "cliBinaryPath") ?? ""
        if !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // Then: canonical install.sh location (`~/.local/bin/shipyard`)
        // and the other paths AppStore already checks. Order matches
        // AppStore.resolveCLIBinary so daemon spawn and general CLI
        // resolution land on the same binary.
        let candidates = [
            "/usr/local/bin/shipyard",
            "/opt/homebrew/bin/shipyard",
            NSHomeDirectory() + "/.pulp/bin/shipyard",
            NSHomeDirectory() + "/.local/bin/shipyard",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Socket path

    /// Mirrors shipyard's `Config.state_dir` on macOS:
    /// `~/Library/Application Support/shipyard/daemon/daemon.sock`.
    /// Nonisolated so background-queue callers (the one-shot
    /// ship-state-list fetcher) can compute the path without hopping
    /// to the main actor just to read an env-derived string.
    nonisolated static func socketPath() -> String {
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
        // Tri-state probe: healthy (skip), absent (spawn), hung
        // (kill-and-spawn). The hung case is the one that used to
        // silently drop us to polling for ~30s until connectSocket's
        // retries gave up; now we detect it up front and recover.
        switch probeDaemon() {
        case .healthy:
            return
        case .absent:
            await spawnDaemon()
        case .hung(let pid):
            await recoverHungDaemon(pid: pid)
            await spawnDaemon()
        }
    }

    /// Spawn a fresh daemon. Treats "already running" as success
    /// because a race with another reconcile / manual `daemon start`
    /// can legitimately find one already up between our probe and
    /// this spawn.
    private func spawnDaemon() async {
        var args = ["daemon", "start"]
        for repo in repos {
            args.append("--repo")
            args.append(repo)
        }
        let (exitCode, output) = await runShipyard(args: args, timeout: 8)
        if exitCode == 0 {
            return
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().contains("already running") {
            return
        }
        // Shipyard CLI 0.22.4+ returns a non-zero exit when the child
        // daemon dies inside the verification window (e.g. PyInstaller
        // bundle missing encodings.idna). Older CLIs exit 0 here even
        // on failure; in that case we silently proceed and let the
        // socket-connect retry loop surface the actual problem.
        let detail = trimmed.isEmpty
            ? "shipyard daemon start exited \(exitCode)"
            : trimmed
        onDisconnect?(detail)
    }

    /// The daemon's accept loop is stuck (pid alive, socket present,
    /// no hello). Try graceful shutdown first; if that doesn't clear
    /// the socket inside a short window, SIGTERM the pid; finally
    /// SIGKILL if still around. Clean up the stale pid/socket files
    /// so the next spawn's `_acquire_lock` path doesn't misdiagnose
    /// the situation.
    private func recoverHungDaemon(pid: pid_t) async {
        // Step 1: `shipyard daemon stop` does the polite shutdown
        // via the IPC socket. Short timeout — if the daemon's
        // accept loop is stuck this call will time out, which is
        // fine; we escalate below.
        _ = await runShipyard(args: ["daemon", "stop"], timeout: 2)

        // Brief wait for clean exit, then check.
        try? await Task.sleep(nanoseconds: 300_000_000)
        if !Self.pidAlive(pid) { cleanupStaleDaemonFiles(); return }

        // Step 2: SIGTERM.
        _ = kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 500_000_000)
        if !Self.pidAlive(pid) { cleanupStaleDaemonFiles(); return }

        // Step 3: SIGKILL — last resort.
        _ = kill(pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 200_000_000)
        cleanupStaleDaemonFiles()
    }

    /// Remove stale daemon.pid + daemon.sock so the next spawn
    /// doesn't have to rely on its own stale-file detection. Best
    /// effort — any failure here isn't fatal; the spawned daemon
    /// will overwrite these on its own startup.
    private func cleanupStaleDaemonFiles() {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Application Support/shipyard/daemon"
        )
        for name in ["daemon.pid", "daemon.sock"] {
            let p = (base as NSString).appendingPathComponent(name)
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    nonisolated private static func pidAlive(_ pid: pid_t) -> Bool {
        // kill(pid, 0) returns 0 if the process exists and we have
        // permission to signal it. ESRCH → gone. Anything else →
        // treat as alive (safer than the alternative).
        kill(pid, 0) == 0
    }

    /// Daemon health outcomes the probe can report.
    ///
    /// - `healthy`: socket accepts + daemon delivered a hello frame.
    ///   No further action needed.
    /// - `hung(pid)`: either the pid file names a live process but
    ///   the socket is dead (socket file removed / accept broken),
    ///   or the socket accepts but never sends hello within the
    ///   deadline. The caller should kill pid + cleanup files
    ///   before spawning fresh.
    /// - `absent`: nothing to clean up; just spawn.
    private enum DaemonProbeResult {
        case healthy
        case hung(pid_t)
        case absent
    }

    /// Three-step probe, each step bounded by a short timeout so a
    /// sick daemon can't hang the GUI:
    ///
    ///   1. non-blocking `connect()` with a 500 ms deadline — catches
    ///      orphan sockets that accept TCP but whose accept loop is
    ///      hung.
    ///   2. after connect succeeds, wait up to 500 ms for the
    ///      daemon's `hello` frame. Every live daemon sends one
    ///      immediately on accept; a hung daemon sitting in a stuck
    ///      accept callback never writes it. No hello → hung.
    ///   3. parse-check the reply for the literal `"hello"` token,
    ///      so we don't confuse the probe with a goodbye-frame
    ///      shutdown race.
    ///
    /// Total worst-case cost: ~1 second before we give up and return
    /// hung/absent. On a healthy daemon it's a sub-millisecond local
    /// round-trip. Cheap enough to run every reconcile.
    private func probeDaemon() -> DaemonProbeResult {
        let socketPath = DaemonClient.socketPath()
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        let pid = Self.readDaemonPidFile()

        // Socket missing AND no live pid → truly absent.
        if !socketExists {
            if let p = pid, Self.pidAlive(p) {
                // pid file points at a live process but the socket
                // file is gone. The daemon process is present but
                // not serving IPC — hung from the GUI's POV.
                return .hung(p)
            }
            return .absent
        }
        // Run the socket probe. If it succeeds, healthy. If not,
        // cross-reference the pid file: if a daemon process is
        // still alive but unresponsive, hung — kill it. If no pid
        // owner, absent — safe to spawn fresh.
        if isSocketResponsive(path: socketPath) {
            return .healthy
        }
        if let p = pid, Self.pidAlive(p) {
            return .hung(p)
        }
        return .absent
    }

    nonisolated private static func readDaemonPidFile() -> pid_t? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Application Support/shipyard/daemon/daemon.pid"
        )
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return nil }
        return pid
    }

    /// Low-level: open the socket, wait for the hello frame within
    /// 500 ms, close. Returns true only if the daemon is actively
    /// serving IPC right now.
    private func isSocketResponsive(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        // Non-blocking mode so `connect()` doesn't hang forever
        // against a kernel-level accept stall.
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        guard flags >= 0,
              Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { cStr in
                for (i, byte) in pathBytes.enumerated() {
                    cStr[i] = CChar(bitPattern: byte)
                }
                cStr[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, addrLen)
            }
        }

        // In non-blocking mode, `connect()` returns -1 with
        // `errno == EINPROGRESS` when the connect is still pending;
        // `0` means it completed immediately (local socket usually).
        // Anything else (ECONNREFUSED, ENOENT) means no live listener.
        if connectResult != 0 {
            let err = errno
            if err != EINPROGRESS {
                return false
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&pfd, 1, 500)
            if ready <= 0 { return false }  // timeout or error
            // connect() can complete "OK" at the syscall level but
            // still carry a deferred error; SO_ERROR is the
            // authoritative post-connect check.
            var sockErr: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) != 0 {
                return false
            }
            if sockErr != 0 { return false }
        }

        // Wait for the hello frame — the real liveness signal.
        // IPCServer.handle_client enqueues the hello before reading
        // any client input, so a responsive daemon lands data here
        // within a few hundred microseconds. A hung accept callback
        // never gets past this poll.
        var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if Darwin.poll(&pollFd, 1, 500) <= 0 { return false }

        var buf = [UInt8](repeating: 0, count: 1024)
        let n = buf.withUnsafeMutableBufferPointer {
            Darwin.read(fd, $0.baseAddress, $0.count)
        }
        if n <= 0 { return false }
        let data = Data(bytes: buf, count: n)
        guard let str = String(data: data, encoding: .utf8) else { return false }
        // Guard against a goodbye-frame race (daemon shutting down
        // replied "goodbye" to a stale subscriber on our shared
        // socket before hello). Only accept the explicit hello.
        return str.contains("\"hello\"")
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

    /// Write an arbitrary pre-formatted NDJSON line. Used by one-shot
    /// request/reply helpers (see `ShipStateListPoller.fetchViaDaemon`)
    /// that need to issue request types outside the three the live
    /// session sends. Line must NOT include a trailing newline — the
    /// method adds one to match the NDJSON framing the daemon expects.
    func sendLine(_ line: String) {
        writeLine(line)
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
