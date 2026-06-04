import Foundation

/// A local **emulated x86_64 smoke** check this Mac can run on demand.
///
/// This is deliberately NOT a `CIServingLane`. A serving lane is a self-hosted
/// GitHub Actions runner LaunchAgent that *picks up pool jobs* and the workflow
/// drives the build. A smoke lane is a one-shot **local** build: the Apple-
/// Silicon guest is ARM64 (no x86 guest exists), so x86_64 is reached by
/// cross-compiling in the guest and running the tests under emulation
/// (qemu-user on Linux, Prism on Windows-ARM). It is a smoke / debug signal —
/// NOT a gate. GitHub-hosted x64 stays authoritative.
///
/// Each lane shells out to [tartci](https://github.com/danielraffel/tartci):
/// `tartci up <os> --target-arch <arch>` (full cross build + emulated ctest), or
/// `… --self-test` (golden-agnostic toolchain+emulator proof). Pure value type so
/// the catalog and argv are unit-testable without a process.
struct CISmokeLane: Identifiable, Equatable {
    let id: String           // stable key, e.g. "linux-x64"
    let title: String        // display, e.g. "Linux x86_64 (emulated)"
    let os: String           // tartci os subcommand: "linux" | "windows"
    let targetArch: String   // "x86_64"

    /// argv passed to the `tartci` binary for the full cross smoke.
    var commandArgs: [String] { ["up", os, "--target-arch", targetArch] }
    /// argv for the lightweight, golden-agnostic toolchain+emulator proof.
    var selfTestArgs: [String] { commandArgs + ["--self-test"] }

    /// Lanes this build knows how to run. Only **wired** emulation paths appear
    /// here — Linux/qemu-user is wired today; Windows/Prism is a tracked tartci
    /// follow-up and is intentionally absent so the UI never offers a path that
    /// would silently no-op.
    static var known: [CISmokeLane] {
        [
            CISmokeLane(id: "linux-x64", title: "Linux x86_64 (emulated)",
                        os: "linux", targetArch: "x86_64"),
        ]
    }
}

/// Where a smoke lane is in its lifecycle.
enum CISmokeState: Equatable {
    case unavailable   // the `tartci` binary isn't installed / discoverable
    case idle          // ready to run
    case running       // a build is in-flight
    case passed        // last run exited 0
    case failed        // last run exited non-zero
}

/// Live status of a smoke lane (value type, testable).
struct CISmokeStatus: Equatable {
    var state: CISmokeState
    /// Short tail / reason from the last run (or a hint when unavailable).
    var detail: String?

    static let unavailable = CISmokeStatus(state: .unavailable, detail: nil)
    static let idle = CISmokeStatus(state: .idle, detail: nil)

    var isRunning: Bool { state == .running }
    var canRun: Bool { state == .idle || state == .passed || state == .failed }

    /// One-line human status for the row.
    var summary: String {
        switch state {
        case .unavailable:
            return "tartci not found — install tartci to run emulated x86_64 smoke"
        case .idle:
            return "Ready — runs a throwaway cross build, then discards the VM"
        case .running:
            return "Running… (cross-compile + emulated tests, a few minutes)"
        case .passed:
            return detail.map { "Passed · \($0)" } ?? "Passed"
        case .failed:
            return detail.map { "Failed · \($0)" } ?? "Failed"
        }
    }

    /// Map a finished process to a terminal state. Pure — unit-tested.
    static func terminal(exitCode: Int32, outputTail: String) -> CISmokeStatus {
        let tail = outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = tail.split(separator: "\n").last.map(String.init) ?? ""
        return CISmokeStatus(
            state: exitCode == 0 ? .passed : .failed,
            detail: lastLine.isEmpty ? nil : String(lastLine.prefix(120)))
    }
}
