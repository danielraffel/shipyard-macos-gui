import Foundation

/// A PR's actual state on github.com — orthogonal to the local
/// ship-state file. A ship-state can linger long after the PR has
/// been merged or closed. Checking this lets us stop showing merged
/// PRs as "awaiting CI".
struct PRState: Equatable {
    let state: String          // OPEN / CLOSED / MERGED
    let isMerged: Bool
    let mergedAt: Date?
    let closedAt: Date?

    var isClosed: Bool { state == "CLOSED" || state == "MERGED" }
}

enum PRStatePoller {
    static func fetch(repo: String, pr: Int) async -> PRState? {
        guard let gh = resolveGH() else { return nil }
        guard let path = apiPath(repo: repo, pr: pr) else { return nil }
        let raw = await runGHCapturing(executable: gh, args: [
            "api", path,
            "--jq", "{state: .state, merged_at: .merged_at, closed_at: .closed_at}",
        ])
        return decodeRESTPayload(raw)
    }

    static func apiPath(repo: String, pr: Int) -> String? {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, pr > 0 else {
            return nil
        }
        return "repos/\(parts[0])/\(parts[1])/pulls/\(pr)"
    }

    static func decodeRESTPayload(_ raw: String) -> PRState? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        struct Raw: Decodable {
            let state: String?
            let mergedAt: String?
            let closedAt: String?

            enum CodingKeys: String, CodingKey {
                case state
                case mergedAt = "merged_at"
                case closedAt = "closed_at"
            }
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let state = (r.state ?? "UNKNOWN").uppercased()
        let merged = (state == "MERGED") || (r.mergedAt != nil && !(r.mergedAt?.isEmpty ?? true))
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        func parse(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            return fmt.date(from: s) ?? fallback.date(from: s)
        }
        return PRState(
            state: merged ? "MERGED" : state,
            isMerged: merged,
            mergedAt: parse(r.mergedAt),
            closedAt: parse(r.closedAt)
        )
    }

    private static func resolveGH() -> String? {
        ShipyardProcessEnvironment.findExecutable(named: "gh", candidates: [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ])
    }
}
