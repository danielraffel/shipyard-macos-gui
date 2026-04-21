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

    /// Start funneling the given local TCP port. Returns the public
    /// HTTPS URL Tailscale announced for this device (derived from
    /// the probe we already did — we don't re-derive it here).
    ///
    /// `--bg` detaches the funnel from the parent process so it
    /// survives after this invocation returns. `tailscale funnel
    /// reset` cleans it up later.
    static func start(binaryPath: String, port: UInt16) async throws {
        let (status, output) = await runCapturing(
            binary: binaryPath,
            args: ["funnel", "--bg", "\(port)"]
        )
        guard status == 0 else {
            throw TunnelError.startFailed(output)
        }
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
