import Foundation

/// Create / update / delete GitHub repository webhooks via the user's
/// existing `gh` CLI auth.
///
/// One hook per (repo, app install). We store the hook ID in
/// UserDefaults keyed by the repo full name so subsequent launches
/// can reuse/refresh it instead of creating duplicates.
enum WebhookRegistrar {

    struct RegisteredHook: Equatable, Codable {
        let repo: String
        let hookId: Int64
    }

    static let subscribedEvents = [
        "workflow_run",
        "workflow_job",
        "pull_request",
        "check_run",
        "check_suite",
    ]

    /// Create a new webhook on `repo` pointing at `url`.
    /// Returns the numeric hook ID on success.
    static func create(
        repo: String,
        url: URL,
        secret: String,
        ghBinary: String
    ) async throws -> Int64 {
        let config: [String: String] = [
            "url": url.absoluteString,
            "content_type": "json",
            "secret": secret,
            "insecure_ssl": "0",
        ]
        let body: [String: Any] = [
            "name": "web",
            "active": true,
            "events": subscribedEvents,
            "config": config,
        ]
        let json = try JSONSerialization.data(withJSONObject: body)
        let (status, output) = await runGH(
            binary: ghBinary,
            args: [
                "api",
                "-X", "POST",
                "-H", "Accept: application/vnd.github+json",
                "--input", "-",
                "repos/\(repo)/hooks",
            ],
            stdin: json
        )
        guard status == 0 else {
            throw ghError(output, fallback: "gh api POST /repos/\(repo)/hooks failed")
        }
        guard let data = output.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int64 ?? (obj["id"] as? Int).map(Int64.init) else {
            throw ghError(output, fallback: "couldn't parse hook ID from gh response")
        }
        return id
    }

    /// Overwrite the `url`/`secret` on an existing hook so a new
    /// Funnel URL takes effect without a second `create`.
    static func update(
        repo: String,
        hookId: Int64,
        url: URL,
        secret: String,
        ghBinary: String
    ) async throws {
        let config: [String: String] = [
            "url": url.absoluteString,
            "content_type": "json",
            "secret": secret,
            "insecure_ssl": "0",
        ]
        let body: [String: Any] = ["config": config, "active": true]
        let json = try JSONSerialization.data(withJSONObject: body)
        let (status, output) = await runGH(
            binary: ghBinary,
            args: [
                "api",
                "-X", "PATCH",
                "-H", "Accept: application/vnd.github+json",
                "--input", "-",
                "repos/\(repo)/hooks/\(hookId)",
            ],
            stdin: json
        )
        guard status == 0 else {
            throw ghError(output, fallback: "gh api PATCH /repos/\(repo)/hooks/\(hookId) failed")
        }
    }

    /// Remove a webhook. Swallows `404` since it's common on reuse
    /// (the hook may have been deleted on github.com).
    static func delete(
        repo: String,
        hookId: Int64,
        ghBinary: String
    ) async throws {
        let (status, output) = await runGH(
            binary: ghBinary,
            args: [
                "api",
                "-X", "DELETE",
                "repos/\(repo)/hooks/\(hookId)",
            ],
            stdin: nil
        )
        if status == 0 { return }
        if output.contains("404") || output.lowercased().contains("not found") { return }
        throw ghError(output, fallback: "gh api DELETE /repos/\(repo)/hooks/\(hookId) failed")
    }

    private static func ghError(_ output: String, fallback: String) -> NSError {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return NSError(
            domain: "WebhookRegistrar",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message]
        )
    }

    private static func runGH(
        binary: String,
        args: [String],
        stdin: Data?
    ) async -> (Int32, String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            if let stdin {
                let inPipe = Pipe()
                process.standardInput = inPipe
                DispatchQueue.global(qos: .utility).async {
                    inPipe.fileHandleForWriting.write(stdin)
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (127, "failed to exec gh: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let merged = (String(data: outData, encoding: .utf8) ?? "")
                    + (String(data: errData, encoding: .utf8) ?? "")
                continuation.resume(returning: (process.terminationStatus, merged))
            }
        }
    }
}
