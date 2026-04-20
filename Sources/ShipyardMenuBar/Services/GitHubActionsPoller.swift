import Foundation

/// Polls `gh run list` for each repo the app has seen ship-states for.
/// Uses the user's existing `gh` auth — no new credentials. Returns runs
/// sorted by recency.
enum GitHubActionsPoller {
    /// Fetch up to `limit` recent runs for one repo. Returns nil on
    /// `gh` auth error or repo not found — caller treats as "skip".
    static func fetch(repo: String, limit: Int = 100) async -> [GitHubRun]? {
        await fetch(repo: repo, branch: nil, limit: limit)
    }

    /// Branch-scoped fetch — used when expanding a ship card so we
    /// pick up runs for that branch even if they're outside the
    /// repo-wide top-100 window. pulp-scale repos burn through 100
    /// recent runs quickly; narrowing to a branch keeps old PRs
    /// visible.
    static func fetch(repo: String, branch: String?, limit: Int = 100) async -> [GitHubRun]? {
        guard let gh = resolveGH() else { return nil }
        var args = [
            "run", "list",
            "--repo", repo,
            "--limit", "\(limit)",
            "--json",
            "databaseId,name,headBranch,headSha,status,conclusion,url,createdAt,updatedAt",
        ]
        if let branch, !branch.isEmpty {
            args.insert(contentsOf: ["--branch", branch], at: 2)
        }
        let raw = await runCapturingStdout(executable: gh, args: args)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        do {
            let decoded = try JSONDecoder.gh.decode([RawRun].self, from: data)
            return decoded.compactMap { $0.toRun(repo: repo) }
        } catch {
            return nil
        }
    }

    private static func resolveGH() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct RawRun: Decodable {
        let databaseId: Int64?
        let name: String?
        let headBranch: String?
        let headSha: String?
        let status: String?
        let conclusion: String?
        let url: String?
        let createdAt: Date?
        let updatedAt: Date?

        func toRun(repo: String) -> GitHubRun? {
            guard let databaseId,
                  let name,
                  let headSha,
                  let status,
                  let createdAt,
                  let updatedAt
            else { return nil }
            return GitHubRun(
                id: databaseId,
                repo: repo,
                workflowName: name,
                headBranch: headBranch ?? "",
                headSha: headSha,
                status: status,
                conclusion: conclusion?.isEmpty == true ? nil : conclusion,
                url: url.flatMap { URL(string: $0) },
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }
}

private func runCapturingStdout(executable: String, args: [String]) async -> String {
    await runGHCapturing(executable: executable, args: args)
}

extension JSONDecoder {
    static let gh: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let fs = ISO8601DateFormatter()
            fs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fs.date(from: raw) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: raw) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable ISO-8601 date from gh: \(raw)"
            )
        }
        return d
    }()
}
