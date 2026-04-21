import Foundation

/// Snapshot of Tailscale daemon readiness for hosting a Funnel.
///
/// Populated by running `tailscale status --json` and parsing the
/// fields that matter for our use case. Pure-data-in/pure-data-out
/// split makes the parser unit-testable without a subprocess.
struct TailscaleStatus: Equatable {
    /// Full path to the `tailscale` CLI binary, or nil if not found.
    let binaryPath: String?
    /// `BackendState` field from `tailscale status --json`. Typical
    /// happy-path value is `"Running"`. Anything else (`Stopped`,
    /// `NeedsLogin`, `NoState`, ...) means not ready.
    let backendState: String?
    /// `Self.DNSName` — the device's `<host>.<tailnet>.ts.net` name,
    /// used as the Funnel URL prefix.
    let dnsName: String?
    /// Whether this node has the `funnel` capability on its tailnet.
    /// Funnel is opt-in per tailnet via ACL.
    let funnelPermitted: Bool

    var isReady: Bool {
        binaryPath != nil
            && backendState == "Running"
            && dnsName?.isEmpty == false
            && funnelPermitted
    }

    var funnelURL: URL? {
        guard isReady, let dns = dnsName, !dns.isEmpty else { return nil }
        let trimmed = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
        return URL(string: "https://\(trimmed)")
    }
}

/// Stateless helpers for detecting Tailscale availability.
///
/// Public surface split into two layers:
///  - `decode(...)` — pure function that converts a `tailscale status --json`
///    response into a `TailscaleStatus`. Unit-testable.
///  - `probe(...)` — shells to the CLI and feeds the output through
///    `decode`. Used at runtime from the main actor via `Task`.
enum TailscaleProbe {

    /// Common install locations for the CLI, in priority order.
    static let candidateBinaries = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale",
    ]

    /// Find the first `tailscale` binary present on disk, or nil.
    static func resolveBinary(candidates: [String] = candidateBinaries,
                             fileManager: FileManager = .default) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Parse `tailscale status --json` output into a `TailscaleStatus`.
    ///
    /// The binary path is passed through as-is (not derived from the
    /// JSON) because the JSON doesn't include it.
    static func decode(json: Data, binaryPath: String?) -> TailscaleStatus {
        guard
            let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            return TailscaleStatus(
                binaryPath: binaryPath,
                backendState: nil,
                dnsName: nil,
                funnelPermitted: false
            )
        }
        let backend = obj["BackendState"] as? String
        let selfObj = obj["Self"] as? [String: Any]
        let dns = selfObj?["DNSName"] as? String
        // Funnel capability shows up in `Self.CapMap`. Presence of
        // the `https://tailscale.com/cap/funnel` key (value is
        // irrelevant) means this node is allowed to run Funnel.
        // Tailscale has moved this key around a few times; we accept
        // either the `https://`-prefixed form or the bare string.
        let capMap = selfObj?["CapMap"] as? [String: Any]
        let funnelKeys = [
            "https://tailscale.com/cap/funnel",
            "funnel",
        ]
        let permitted = funnelKeys.contains { capMap?[$0] != nil }
        return TailscaleStatus(
            binaryPath: binaryPath,
            backendState: backend,
            dnsName: dns,
            funnelPermitted: permitted
        )
    }

    /// Run `tailscale status --json` and return the parsed status.
    /// Returns a "not installed" status if the binary is missing.
    static func probe() async -> TailscaleStatus {
        guard let binary = resolveBinary() else {
            return TailscaleStatus(
                binaryPath: nil,
                backendState: nil,
                dnsName: nil,
                funnelPermitted: false
            )
        }
        let output = await runProcess(binary: binary, args: ["status", "--json"])
        guard let data = output.data(using: .utf8) else {
            return TailscaleStatus(
                binaryPath: binary,
                backendState: nil,
                dnsName: nil,
                funnelPermitted: false
            )
        }
        return decode(json: data, binaryPath: binary)
    }

    private static func runProcess(binary: String, args: [String]) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                continuation.resume(returning: "")
                return
            }
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: text)
            }
        }
    }
}
