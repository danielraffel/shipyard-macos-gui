import Foundation

/// Host-wide cap on how many macOS CI VMs may run at once on THIS Mac.
///
/// Apple allows at most **2** macOS guests per host, so the range is 1...2. The
/// tartci macOS runners read this value LIVE from `~/.config/tartci/macos-vm-cap`
/// on every poll, so changing it here takes effect within one poll — no runner
/// reload needed. Set it to **1** to keep a VM slot free while you're working;
/// **2** lets the Mac run the full pair (e.g. gate + release lanes together).
///
/// This is the GUI half of the same contract the runner enforces in
/// `~/.config/tartci/macos-vm-cap.lib.sh` (`tartci_effective_cap`): a single
/// integer, clamped >= 1, missing/garbage ⇒ the default.
enum MacOSVMCap {
    static let minCap = 1
    static let maxCap = 2
    static let defaultCap = 2

    static func defaultPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".config/tartci/macos-vm-cap")
    }

    static func clamp(_ n: Int) -> Int { min(maxCap, max(minCap, n)) }

    /// Current cap. Missing/invalid file ⇒ `defaultCap`. Always clamped to 1...2.
    /// Takes the leading run of digits, requires >= 1, else default. (The runner
    /// instead concatenates all digits via `tr -dc '0-9' | head -c 2`; the two
    /// agree for the single-integer files this GUI writes — the only writer. The
    /// GUI additionally clamps the upper bound, which the runner does not.)
    static func read(path: String = defaultPath()) -> Int {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return defaultCap }
        let digits = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber })
        guard let n = Int(digits), n >= minCap else { return defaultCap }
        return clamp(n)
    }

    /// Write the cap (clamped). Creates `~/.config/tartci` if needed. The trailing
    /// newline matches what the shell side writes. Returns whether the write stuck.
    @discardableResult
    static func write(_ n: Int, path: String = defaultPath(), fileManager: FileManager = .default) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try? "\(clamp(n))\n".write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}
