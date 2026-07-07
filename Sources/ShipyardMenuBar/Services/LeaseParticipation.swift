import Foundation

/// Whether THIS Mac offers itself for native-build leases from the tartci
/// governor. A sibling of `MacOSVMCap`: a single flag file the governor reads
/// live from `~/.config/tartci/native-build-participation` — `1` = participating
/// (the default when the file is absent), `0` = opted out.
///
/// The flag is OWNED by the single `tartci pool {on|off}` implementation (which
/// writes it AND loads/unloads the runner agents in one step; see `CIPool`). The
/// GUI no longer writes it — it only *reads* it here as a fallback for
/// `tartci pool status --json` when tartci isn't on PATH, so the participation
/// header still reflects the true on-disk state on a host without the CLI.
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
}
