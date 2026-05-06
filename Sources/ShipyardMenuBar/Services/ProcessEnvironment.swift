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
}
