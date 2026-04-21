import Foundation

/// Snapshot of the user's GitHub REST rate-limit state.
///
/// Polled periodically so the UI can render a banner when the budget
/// is exhausted. The `/rate_limit` endpoint itself doesn't count
/// against your limit (it's free), so checking it frequently is fine.
struct GitHubRateLimit: Equatable {
    let used: Int
    let limit: Int
    let remaining: Int
    let resetAt: Date

    /// True when the budget is blown and polling calls are being
    /// rejected with HTTP 403. UI shows an informational banner
    /// during this window.
    var isExceeded: Bool { remaining <= 0 }

    /// Near-exhausted — worth warning about before it blows up.
    var isNearExhaustion: Bool { remaining > 0 && remaining < 100 }
}

enum GitHubRateLimitPoller {
    /// Fetch the user's REST rate-limit state via `gh api /rate_limit`.
    /// Returns nil on any transport / auth failure — the caller treats
    /// that as "unknown, don't render a banner."
    static func fetch() async -> GitHubRateLimit? {
        guard let gh = resolveGH() else { return nil }
        let raw = await runCapturing(
            executable: gh,
            args: ["api", "/rate_limit"]
        )
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        struct Outer: Decodable {
            let rate: Rate
            struct Rate: Decodable {
                let used: Int
                let limit: Int
                let remaining: Int
                let reset: Int
            }
        }
        guard let decoded = try? JSONDecoder().decode(Outer.self, from: data) else {
            return nil
        }
        return GitHubRateLimit(
            used: decoded.rate.used,
            limit: decoded.rate.limit,
            remaining: decoded.rate.remaining,
            resetAt: Date(timeIntervalSince1970: TimeInterval(decoded.rate.reset))
        )
    }

    private static func resolveGH() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runCapturing(
        executable: String,
        args: [String]
    ) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
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
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
