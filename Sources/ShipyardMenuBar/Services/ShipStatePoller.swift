import Foundation

/// Wraps `shipyard ship-state list --json`. Not a long-lived subprocess —
/// we invoke it on a timer and feed the result up to the store so the UI
/// can reflect ships that were shipped by a CLI session that isn't
/// currently running `watch`.
struct ShipStateListEntry: Decodable {
    let pr: Int
    let branch: String?
    let headSha: String?
    let repo: String?
    let worktree: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case pr, branch, repo, worktree
        case headSha = "head_sha"
        case updatedAt = "updated_at"
    }
}

enum ShipStateListPoller {
    /// Returns the active ship-state list, or nil if the CLI isn't
    /// available / returned an error we can't parse.
    static func fetch(binary: String) async -> [ShipStateListEntry]? {
        let raw = await runShipyardCapturingStdout(
            binary: binary,
            args: ["ship-state", "list", "--json"]
        )
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }

        // The CLI can emit either:
        //   { "ship-state": { "event": "list", "ships": [ … ] } }
        //   [ … ]
        //   { "event": "list", "ships": [ … ] }
        // Be tolerant of all three.
        if let envelope = try? JSONDecoder.shipyard.decode(Envelope.self, from: data) {
            return envelope.ships
        }
        if let inner = try? JSONDecoder.shipyard.decode([String: Envelope].self, from: data),
           let first = inner.values.first {
            return first.ships
        }
        if let array = try? JSONDecoder.shipyard.decode([ShipStateListEntry].self, from: data) {
            return array
        }
        return nil
    }

    private struct Envelope: Decodable {
        let ships: [ShipStateListEntry]
    }
}

/// Runs `binary args...`, waits for exit, returns stdout as a String.
/// Captures nothing from stderr (we don't surface it here; callers can
/// add logging when they care).
func runShipyardCapturingStdout(binary: String, args: [String]) async -> String {
    await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                cont.resume(returning: "")
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
