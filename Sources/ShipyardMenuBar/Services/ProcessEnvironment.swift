import Foundation

/// Finder/login-item launches inherit a minimal PATH, unlike Terminal.
/// Every CLI subprocess should use this environment so `shipyard` can
/// find user-installed helpers such as `gh`, `nsc`, and Homebrew tools.
enum ShipyardProcessEnvironment {
    static func augmented(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = augmentedPath(from: base["PATH"])
        // ghapp's token mint reads $HOME/.config/shipyard; ensure HOME is set under
        // a Finder/login-item launch that may strip it.
        if environment["HOME"]?.isEmpty ?? true { environment["HOME"] = NSHomeDirectory() }
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }

    static func augmentedPath(from rawPath: String?) -> String {
        let home = NSHomeDirectory()
        var directories: [String] = []

        func append(_ directory: String) {
            guard !directory.isEmpty, !directories.contains(directory) else { return }
            directories.append(directory)
        }

        [
            home + "/.local/bin",
            home + "/.pulp/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/Tailscale.app/Contents/MacOS",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].forEach(append)

        rawPath?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .forEach(append)

        return directories.joined(separator: ":")
    }

    static func configure(_ process: Process, extra: [String: String] = [:]) {
        process.environment = augmented(extra: extra)
    }

    static func findExecutable(
        named name: String,
        candidates: [String] = [],
        fileManager: FileManager = .default
    ) -> String? {
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        for directory in augmentedPath(from: ProcessInfo.processInfo.environment["PATH"])
            .split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = String(directory) + "/" + name
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Resolve the GitHub CLI for API polling. Prefer `ghapp` (wraps `gh` with the
    /// Shipyard App installation token → off the personal PAT, onto the App's
    /// 12,500/hr bucket); fall back to `gh` when ghapp isn't installed. `ghapp`
    /// forwards identical `gh`-style args, so callers are unchanged.
    static func resolveGitHubCLI() -> String? {
        // Prefer ghapp ONLY if its App-token setup is actually present, so a host
        // that has the ghapp script copied but no App key/helper falls back to plain
        // `gh` instead of silently losing all polling (ghapp would exit empty).
        if let ghapp = findExecutable(named: "ghapp", candidates: [
            NSHomeDirectory() + "/.local/bin/ghapp",
        ]), ghappTokenSetupPresent() {
            return ghapp
        }
        return findExecutable(named: "gh", candidates: [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ])
    }

    /// ghapp mints a Shipyard App installation token at runtime; it only works if the
    /// App private key + the token-mint helper are installed on this host.
    static func ghappTokenSetupPresent(fileManager: FileManager = .default) -> Bool {
        let home = NSHomeDirectory()
        return fileManager.fileExists(
            atPath: home + "/.config/shipyard/github-apps/shipyard-local.private-key.pem")
            && fileManager.isExecutableFile(
                atPath: home + "/.config/shipyard/bin/gh-app-token-cached")
            // gh-app-token-cached shells out to this mint binary; without it ghapp
            // would pass this guard but exit with an empty token at runtime.
            && fileManager.isExecutableFile(
                atPath: home + "/.config/shipyard/bin/shipyard-github-app-token")
    }
}
