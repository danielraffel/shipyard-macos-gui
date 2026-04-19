import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var ships: [Ship] = []

    @Published var cliBinaryPath: String = UserDefaults.standard.string(forKey: Keys.cliBinaryPath) ?? "" {
        didSet { UserDefaults.standard.set(cliBinaryPath, forKey: Keys.cliBinaryPath); resolveCLIBinary() }
    }

    @Published var cliBinaryResolved: String?
    @Published var cliBinaryError: String?

    @Published var lastDoctorCheckedAt: Date?
    @Published var doctorResult: DoctorResult?

    @Published var notifyOnFail: Bool = UserDefaults.standard.object(forKey: Keys.notifyOnFail) as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnFail, forKey: Keys.notifyOnFail) }
    }
    @Published var notifyOnGreen: Bool = UserDefaults.standard.object(forKey: Keys.notifyOnGreen) as? Bool ?? false {
        didSet { UserDefaults.standard.set(notifyOnGreen, forKey: Keys.notifyOnGreen) }
    }
    @Published var notifyOnMerge: Bool = UserDefaults.standard.object(forKey: Keys.notifyOnMerge) as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnMerge, forKey: Keys.notifyOnMerge) }
    }
    @Published var resumePromptOnWake: Bool = UserDefaults.standard.bool(forKey: Keys.resumePromptOnWake) {
        didSet { UserDefaults.standard.set(resumePromptOnWake, forKey: Keys.resumePromptOnWake) }
    }
    @Published var autoClearPassedMinutes: Int = UserDefaults.standard.object(forKey: Keys.autoClearPassedMinutes) as? Int ?? 60 {
        didSet { UserDefaults.standard.set(autoClearPassedMinutes, forKey: Keys.autoClearPassedMinutes) }
    }
    @Published var autoClearFailedMinutes: Int = UserDefaults.standard.object(forKey: Keys.autoClearFailedMinutes) as? Int ?? 240 {
        didSet { UserDefaults.standard.set(autoClearFailedMinutes, forKey: Keys.autoClearFailedMinutes) }
    }
    @Published var groupByWorktree: Bool = UserDefaults.standard.bool(forKey: Keys.groupByWorktree) {
        didSet { UserDefaults.standard.set(groupByWorktree, forKey: Keys.groupByWorktree) }
    }

    var overallBadge: OverallBadge {
        ships.filter { !$0.dismissed }.overallBadge
    }

    init() {
        resolveCLIBinary()
    }

    func dismiss(ship: Ship) {
        guard let index = ships.firstIndex(where: { $0.id == ship.id }) else { return }
        ships[index].dismissed = true
    }

    func clearCompleted() {
        ships.removeAll { $0.overallStatus == .passed || $0.overallStatus == .failed }
    }

    func resolveCLIBinary() {
        if !cliBinaryPath.isEmpty, FileManager.default.isExecutableFile(atPath: cliBinaryPath) {
            cliBinaryResolved = cliBinaryPath
            cliBinaryError = nil
            return
        }
        let candidates = [
            "/usr/local/bin/shipyard",
            "/opt/homebrew/bin/shipyard",
            NSHomeDirectory() + "/.local/bin/shipyard",
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cliBinaryResolved = candidate
                cliBinaryError = nil
                return
            }
        }
        cliBinaryResolved = nil
        cliBinaryError = "shipyard binary not found. Set path in Settings or install the CLI first."
    }

    private enum Keys {
        static let cliBinaryPath = "cliBinaryPath"
        static let notifyOnFail = "notifyOnFail"
        static let notifyOnGreen = "notifyOnGreen"
        static let notifyOnMerge = "notifyOnMerge"
        static let resumePromptOnWake = "resumePromptOnWake"
        static let autoClearPassedMinutes = "autoClearPassedMinutes"
        static let autoClearFailedMinutes = "autoClearFailedMinutes"
        static let groupByWorktree = "groupByWorktree"
    }
}

struct DoctorResult: Equatable {
    let ok: Bool
    let checks: [String: Bool]
    let rawJSON: String
}
