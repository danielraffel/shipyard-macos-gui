import Foundation

enum RoutingProfilesError: Error, LocalizedError {
    case invalidOutput(String)
    case commandFailed(String)
    case localUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidOutput(let message): return message
        case .commandFailed(let message): return message
        case .localUnsupported:
            return "Update Shipyard to a version that supports `config use --local`."
        }
    }
}

/// Reads and writes the per-repo routing profile via the `shipyard config`
/// subcommands, run in the selected repo's checkout directory.
enum RoutingProfilesService {
    private static let decoder = JSONDecoder()

    /// `shipyard --json config profiles` in `repoRoot`.
    static func fetchProfiles(binary: String, repoRoot: String) async throws -> RoutingProfilesSnapshot {
        let result = await ShipyardCommandRunner.run(
            binary: binary,
            args: ["--json", "config", "profiles"],
            currentDirectoryPath: repoRoot)
        return try decodeSnapshot(result)
    }

    /// `shipyard --json config use <profile> --local`, then re-read to confirm.
    static func useProfileLocally(
        binary: String,
        repoRoot: String,
        profileName: String
    ) async throws -> RoutingProfilesSnapshot {
        let result = await ShipyardCommandRunner.run(
            binary: binary,
            args: ["--json", "config", "use", profileName, "--local"],
            currentDirectoryPath: repoRoot)
        if !result.succeeded {
            let message = preferredMessage(result)
            let lower = message.lowercased()
            if lower.contains("--local") || lower.contains("unexpected argument") {
                throw RoutingProfilesError.localUnsupported
            }
            throw RoutingProfilesError.commandFailed(
                message.isEmpty ? "`config use --local` failed (exit \(result.exitCode))." : message)
        }
        // Always re-read so the UI reflects confirmed state, never an optimistic guess.
        return try await fetchProfiles(binary: binary, repoRoot: repoRoot)
    }

    /// Probe whether this CLI supports the writable local switch, so the GUI can
    /// gate Phase-2 writes before the user attempts a save.
    static func supportsLocalWrite(binary: String, repoRoot: String) async -> Bool {
        let result = await ShipyardCommandRunner.run(
            binary: binary,
            args: ["config", "use", "--help"],
            currentDirectoryPath: repoRoot,
            timeout: 15)
        return (result.stdout + result.stderr).contains("--local")
    }

    private static func decodeSnapshot(_ result: ShipyardCommandResult) throws -> RoutingProfilesSnapshot {
        guard !result.stdout.isEmpty, let data = result.stdout.data(using: .utf8) else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RoutingProfilesError.invalidOutput(
                err.isEmpty ? "Shipyard returned no routing data." : err)
        }
        do {
            return try decoder.decode(RoutingProfilesSnapshot.self, from: data)
        } catch {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RoutingProfilesError.invalidOutput(
                err.isEmpty ? "Shipyard did not return valid routing data." : err)
        }
    }

    private static func preferredMessage(_ result: ShipyardCommandResult) -> String {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
