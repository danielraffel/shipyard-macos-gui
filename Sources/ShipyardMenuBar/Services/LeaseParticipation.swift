import Foundation

/// Whether THIS Mac offers itself for native-build leases from the tartci
/// governor. A sibling of `MacOSVMCap`: a single flag file the governor reads
/// live from `~/.config/tartci/native-build-participation` — `1` = participating
/// (the default when the file is absent), `0` = opted out.
///
/// Unloading the runner LaunchAgents (via `CIServingService.setServing`) stops
/// this Mac from *picking up* GitHub-dispatched jobs; this flag additionally
/// lets a future governor *refuse* to place a native-build lease here at all —
/// so an opted-out host is left alone even by lease paths that don't go through
/// launchd. Each Mac governs only its own host (matching the local-only design),
/// so there's no remote write.
enum LeaseParticipation {
    /// Absent file ⇒ participating: a freshly-onboarded host is in the pool until
    /// its owner opts out, matching the runner-agents-loaded default.
    static let defaultParticipating = true

    static func defaultPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".config/tartci/native-build-participation")
    }

    /// Current participation. Missing file ⇒ `defaultParticipating`. Reads the
    /// leading digit: `0` (any leading run of zeros) ⇒ opted out, any other
    /// leading digit ⇒ participating; garbage/empty ⇒ the default.
    static func read(path: String = defaultPath()) -> Bool {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return defaultParticipating
        }
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber }
        guard let n = Int(digits) else { return defaultParticipating }
        return n != 0
    }

    /// Write the flag (`1`/`0` + trailing newline, matching the shell-side
    /// writers). Creates `~/.config/tartci` if needed. Returns whether the write
    /// stuck, so a caller can avoid claiming an opt-out that never reached disk.
    @discardableResult
    static func write(_ participating: Bool, path: String = defaultPath(),
                      fileManager: FileManager = .default) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let value = participating ? "1" : "0"
        return (try? "\(value)\n".write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// Host-wide participation implied by a single per-lane toggle: turning any
    /// lane ON means this host participates; turning a lane OFF only opts the
    /// host out when NO other lane will still be serving afterward. Pure so the
    /// aggregate rule is testable without standing up an AppStore.
    static func hostParticipating(togglingOn on: Bool, otherLanesServing: Bool) -> Bool {
        on || otherLanesServing
    }
}
