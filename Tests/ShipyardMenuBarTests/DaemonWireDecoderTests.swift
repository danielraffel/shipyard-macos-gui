import XCTest
@testable import Shipyard

/// Exercises the GUI-side parser for daemon NDJSON output. The daemon
/// (in the shipyard CLI) sends pre-decoded events with snake_case
/// fields; this test pins the mapping from those wire payloads to the
/// Swift `WebhookEvent` enum so a wire-format drift can't silently
/// break the macOS app's platform-dot rollup or merged-pill logic.
final class DaemonWireDecoderTests: XCTestCase {

    func test_workflowRun_decodesAllFields() {
        let obj: [String: Any] = [
            "kind": "workflow_run",
            "payload": [
                "action": "completed",
                "run_id": 42,
                "repo": "org/repo",
                "head_branch": "feature/x",
                "head_sha": "abc",
                "status": "completed",
                "conclusion": "success",
                "workflow_name": "CI",
                "html_url": "https://github.com/org/repo/actions/runs/42",
            ],
        ]
        guard case .workflowRun(let p) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected workflowRun")
            return
        }
        XCTAssertEqual(p.runId, 42)
        XCTAssertEqual(p.action, "completed")
        XCTAssertEqual(p.repo, "org/repo")
        XCTAssertEqual(p.headBranch, "feature/x")
        XCTAssertEqual(p.conclusion, "success")
        XCTAssertEqual(p.workflowName, "CI")
    }

    func test_workflowJob_decodesMatrixLabels() {
        let obj: [String: Any] = [
            "kind": "workflow_job",
            "payload": [
                "action": "in_progress",
                "run_id": 100,
                "job_id": 999,
                "repo": "org/repo",
                "name": "macOS (arm64)",
                "status": "in_progress",
                "conclusion": NSNull(),
                "runner_name": "macOS-arm64-1",
                "labels": ["self-hosted", "macOS"],
            ],
        ]
        guard case .workflowJob(let p) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected workflowJob")
            return
        }
        XCTAssertEqual(p.jobId, 999)
        XCTAssertEqual(p.runId, 100)
        XCTAssertEqual(p.status, "in_progress")
        XCTAssertNil(p.conclusion)
        XCTAssertEqual(p.labels, ["self-hosted", "macOS"])
    }

    func test_pullRequest_decodesMergedState() {
        let obj: [String: Any] = [
            "kind": "pull_request",
            "payload": [
                "action": "closed",
                "number": 581,
                "repo": "org/repo",
                "state": "closed",
                "merged": true,
                "merged_at": "2026-04-20T12:00:00Z",
                "closed_at": "2026-04-20T12:00:00Z",
            ],
        ]
        guard case .pullRequest(let p) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected pullRequest")
            return
        }
        XCTAssertEqual(p.number, 581)
        XCTAssertEqual(p.state, "closed")
        XCTAssertTrue(p.merged)
    }

    func test_stateArchived_decodesTerminalShipStateEvent() {
        let obj: [String: Any] = [
            "kind": "state-archived",
            "payload": [
                "pr": 581,
                "repo": "org/repo",
                "source": "pull_request.closed",
                "message": "PR #581 merged; archived local ship state.",
            ],
        ]
        guard case .stateArchived(let p) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected stateArchived")
            return
        }
        XCTAssertEqual(p.pr, 581)
        XCTAssertEqual(p.repo, "org/repo")
        XCTAssertEqual(p.source, "pull_request.closed")
    }

    func test_unhandledKindFallsThrough() {
        let obj: [String: Any] = [
            "kind": "unhandled",
            "type": "star",
        ]
        guard case .unhandled(let type) = DaemonWireDecoder.decodeEvent(obj) else {
            XCTFail("expected unhandled")
            return
        }
        XCTAssertEqual(type, "star")
    }

    func test_unknownKindReturnsNil() {
        XCTAssertNil(DaemonWireDecoder.decodeEvent([
            "kind": "not-a-real-event",
            "payload": [:],
        ]))
    }

    func test_statusDecodesTunnelFields() {
        let obj: [String: Any] = [
            "type": "status",
            "tunnel": [
                "backend": "tailscale",
                "url": "https://foo.ts.net",
                "verified_at": NSNull(),
            ],
            "subscribers": 3,
            "last_event_at": NSNull(),
            "registered_repos": ["org/repo"],
            "last_error": "GitHub webhook management needs admin:repo_hook",
        ]
        let status = DaemonWireDecoder.decodeStatus(obj)
        XCTAssertEqual(status.tunnelBackend, "tailscale")
        XCTAssertEqual(status.tunnelURL?.absoluteString, "https://foo.ts.net")
        XCTAssertEqual(status.subscribers, 3)
        XCTAssertEqual(status.registeredRepos, ["org/repo"])
        XCTAssertEqual(status.lastError, "GitHub webhook management needs admin:repo_hook")
    }

    func test_decideLetsDaemonOwnAutoModeTailscaleDiagnosis() {
        let notInstalled = TailscaleStatus(
            binaryPath: nil,
            backendState: nil,
            dnsName: nil,
            funnelPermitted: false
        )
        let d = DaemonClient.decide(mode: .auto, tailscale: notInstalled)
        XCTAssertTrue(d.attemptLive)
        XCTAssertNil(d.reason)
    }

    func test_decideRefusesToAttemptWhenOff() {
        let ready = TailscaleStatus(
            binaryPath: "/opt/homebrew/bin/tailscale",
            backendState: "Running",
            dnsName: "foo.ts.net",
            funnelPermitted: true
        )
        let d = DaemonClient.decide(mode: .off, tailscale: ready)
        XCTAssertFalse(d.attemptLive)
        XCTAssertEqual(d.reason, .userDisabled)
    }

    func test_pollingReasonDetectsMissingWebhookScope() {
        let reason = LiveUpdateStatus.PollingReason.tunnelStartFailed(
            #"gh: This API operation needs the "admin:repo_hook" scope."#
        )
        XCTAssertTrue(reason.isWebhookScopeMissing)
        XCTAssertTrue(reason.shouldWarn)
        XCTAssertEqual(reason.headerLabel, "polling · hook auth")
        XCTAssertEqual(
            LiveUpdateStatus.PollingReason.webhookScopeCommand,
            "gh auth refresh -h github.com -s admin:repo_hook"
        )
        XCTAssertTrue(reason.userFacing.contains("Polling continues"))
    }

    func test_transientNoTunnelStatusDoesNotDowngradeDuringSocketWarmup() {
        let status = DaemonStatus(
            tunnelBackend: "inactive",
            tunnelURL: nil,
            subscribers: 1,
            registeredRepos: ["org/repo"],
            lastError: nil
        )
        let update = DaemonClient.statusUpdate(
            daemonStatus: status,
            lastEventAt: nil,
            allowMissingTunnelDowngrade: false
        )
        XCTAssertNil(update)
    }

    func test_boundedStatusSnapshotCanDowngradeWhenTunnelNeverAppears() {
        let status = DaemonStatus(
            tunnelBackend: "inactive",
            tunnelURL: nil,
            subscribers: 1,
            registeredRepos: ["org/repo"],
            lastError: nil
        )
        let update = DaemonClient.statusUpdate(
            daemonStatus: status,
            lastEventAt: nil,
            allowMissingTunnelDowngrade: true
        )
        XCTAssertEqual(update, .polling(reason: .tunnelStartFailed("daemon reported no tunnel")))
    }

    func test_statusUpdateSurfacesDaemonErrorsImmediately() {
        let status = DaemonStatus(
            tunnelBackend: "inactive",
            tunnelURL: nil,
            subscribers: 1,
            registeredRepos: ["org/repo"],
            lastError: "tailscale funnel failed"
        )
        let update = DaemonClient.statusUpdate(
            daemonStatus: status,
            lastEventAt: nil,
            allowMissingTunnelDowngrade: false
        )
        XCTAssertEqual(update, .polling(reason: .tunnelStartFailed("tailscale funnel failed")))
    }

    func test_runtimePathsDecodeRustPathsOutput() {
        let json = """
        {
          "mode": "isolated",
          "daemon_dir": "/tmp/shipyard-rust-dev/daemon",
          "daemon_socket": "/tmp/shipyard-rust-dev/daemon/daemon.sock",
          "daemon_pid_file": "/tmp/shipyard-rust-dev/daemon/daemon.pid"
        }
        """
        let paths = DaemonRuntimePaths.decode(json: json)
        XCTAssertEqual(paths?.daemonDir, "/tmp/shipyard-rust-dev/daemon")
        XCTAssertEqual(paths?.socketPath, "/tmp/shipyard-rust-dev/daemon/daemon.sock")
        XCTAssertEqual(paths?.pidFilePath, "/tmp/shipyard-rust-dev/daemon/daemon.pid")
    }

    func test_runtimePathsDecodeFallsBackToSocketDirectoryWhenDaemonDirMissing() {
        let json = """
        {
          "daemon_socket": "/tmp/shipyard-rust-dev/daemon/daemon.sock",
          "daemon_pid_file": "/tmp/shipyard-rust-dev/daemon/daemon.pid"
        }
        """
        let paths = DaemonRuntimePaths.decode(json: json)
        XCTAssertEqual(paths?.daemonDir, "/tmp/shipyard-rust-dev/daemon")
    }

    func test_runtimePathResolverUsesSelectedCliPathsCommand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeCLI = dir.appendingPathComponent("shipyard")
        try """
        #!/bin/sh
        if [ "$1" = "--json" ] && [ "$2" = "paths" ]; then
          cat <<'JSON'
        {"daemon_dir":"/tmp/rust-daemon","daemon_socket":"/tmp/rust-daemon/daemon.sock","daemon_pid_file":"/tmp/rust-daemon/daemon.pid"}
        JSON
          exit 0
        fi
        exit 2
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let paths = DaemonRuntimePathResolver.paths(for: fakeCLI.path)
        XCTAssertEqual(paths.socketPath, "/tmp/rust-daemon/daemon.sock")
        XCTAssertEqual(paths.pidFilePath, "/tmp/rust-daemon/daemon.pid")
    }

    func test_runtimePathResolverFallsBackForLegacyCliWithoutPathsCommand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeCLI = dir.appendingPathComponent("shipyard")
        try """
        #!/bin/sh
        exit 2
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let paths = DaemonRuntimePathResolver.paths(for: fakeCLI.path)
        XCTAssertEqual(paths, DaemonRuntimePaths.legacy())
    }

    func test_signedRustBinaryOverrideMatchesGuiContracts() throws {
        guard let binary = ProcessInfo.processInfo.environment["SHIPYARD_GUI_TEST_RUST_BINARY"],
              !binary.isEmpty
        else {
            throw XCTSkip("Set SHIPYARD_GUI_TEST_RUST_BINARY to validate a signed Rust CLI artifact")
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary))

        let pathsOutput = try runShipyard(binary, ["--json", "paths"])
        let paths = DaemonRuntimePaths.decode(json: pathsOutput)
        XCTAssertNotNil(paths)
        XCTAssertFalse(paths?.socketPath.isEmpty ?? true)
        XCTAssertFalse(paths?.pidFilePath.isEmpty ?? true)

        let doctorOutput = try runShipyard(binary, ["--json", "doctor"])
        let data = try XCTUnwrap(doctorOutput.data(using: .utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["command"] as? String, "doctor")
        XCTAssertEqual(json["ready"] as? Bool, true)
        let checks = try XCTUnwrap(json["checks"] as? [String: Any])
        XCTAssertNotNil(checks["Core"])
    }

    private func runShipyard(_ binary: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            group.leave()
        }

        guard group.wait(timeout: .now() + 5) == .success else {
            if process.isRunning {
                process.terminate()
            }
            XCTFail("shipyard command timed out: \(arguments.joined(separator: " "))")
            return ""
        }
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "shipyard \(arguments.joined(separator: " ")) failed: \(stderrText)"
        )
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }
}
