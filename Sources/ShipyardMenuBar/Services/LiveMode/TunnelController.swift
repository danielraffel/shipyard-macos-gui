import Foundation

/// Manages a Tailscale Funnel subprocess lifecycle.
///
/// Tailscale's CLI surface for Funnel has churned a bit, so we use
/// the form that's stable across recent versions:
///
///   tailscale funnel --bg <port>     # expose http://127.0.0.1:<port>
///   tailscale funnel --bg off        # stop (approx; see below)
///
/// For the off path we prefer `tailscale funnel reset` which wipes
/// any configured serve/funnel state — simplest and most robust
/// across CLI revisions.
enum TunnelController {

    enum TunnelError: Error, Equatable {
        case tailscaleNotFound
        case startFailed(String)
        case stopFailed(String)
    }

    /// Start funneling the given local TCP port.
    ///
    /// Always `tailscale funnel reset` first so a previous launch's
    /// mapping doesn't silently win — `--bg <newport>` does NOT
    /// replace an existing `/` → old-port proxy, it's a no-op when
    /// the root path is already claimed. After `--bg`, verify the
    /// serve config actually took effect — Tailscale has been known
    /// to return exit 0 without persisting the config when reset and
    /// --bg land back-to-back too quickly. Retry up to 3× with a
    /// small backoff; throw `startFailed` if we still can't confirm
    /// the proxy is live.
    static func start(binaryPath: String, port: UInt16) async throws {
        _ = await runCapturing(
            binary: binaryPath,
            args: ["funnel", "reset"]
        )
        // Brief pause lets the daemon settle after reset before we
        // re-configure — avoids the race where the config command
        // succeeds but the daemon still has the reset in-flight.
        try? await Task.sleep(nanoseconds: 500_000_000)

        var lastOutput = ""
        for attempt in 1...3 {
            let (status, output) = await runCapturing(
                binary: binaryPath,
                args: ["funnel", "--bg", "\(port)"]
            )
            lastOutput = output
            if status != 0 {
                // Surface non-zero exits immediately — retrying won't
                // paper over a rejected config.
                throw TunnelError.startFailed(output)
            }
            // Verify the daemon actually persisted the route. If it
            // didn't, retry with a slightly longer backoff.
            if await verifyPortConfigured(binaryPath: binaryPath, port: port) {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt))
        }
        throw TunnelError.startFailed(
            "funnel --bg returned 0 but serve config didn't persist after 3 attempts. Last output:\n\(lastOutput)"
        )
    }

    /// Query `tailscale funnel status` and confirm the expected local
    /// port is reflected in the serve mapping.
    private static func verifyPortConfigured(
        binaryPath: String,
        port: UInt16
    ) async -> Bool {
        let (_, output) = await runCapturing(
            binary: binaryPath,
            args: ["funnel", "status"]
        )
        return output.contains("127.0.0.1:\(port)")
    }

    /// Wipe all serve/funnel configuration. Safe to call even when
    /// nothing is currently configured.
    static func stop(binaryPath: String) async throws {
        let (status, output) = await runCapturing(
            binary: binaryPath,
            args: ["funnel", "reset"]
        )
        if status != 0 {
            throw TunnelError.stopFailed(output)
        }
    }

    /// Subprocess runner that returns (exitCode, mergedStdoutStderr).
    private static func runCapturing(
        binary: String,
        args: [String]
    ) async -> (Int32, String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (127, "failed to exec: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }
    }
}
