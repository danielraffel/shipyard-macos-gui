import XCTest
@testable import Shipyard

final class GitHubRunTests: XCTestCase {
    private func job(runner: String? = nil, labels: [String]? = nil) -> GitHubJob {
        GitHubJob(databaseId: 1, name: "build", status: "completed",
                  conclusion: "success", labels: labels, runnerName: runner)
    }

    func testMachineFromHostTags() {
        // Host tags are the reliable signal for the Linux/Windows lanes.
        XCTAssertEqual(job(labels: ["self-hosted", "Linux", "ARM64", "pulp-build-linux", "pulp-host-m5"]).machine, "M5")
        XCTAssertEqual(job(labels: ["self-hosted", "Windows", "ARM64", "pulp-build-windows", "pulp-host-m1"]).machine, "M1")
    }

    func testMachineFromStudioRunnerName() {
        XCTAssertEqual(job(runner: "pulp-studio-01").machine, "Mac Studio")
        XCTAssertEqual(job(runner: "pulp-studio-03").machine, "Mac Studio")
    }

    func testMachineHostedAndNamespace() {
        XCTAssertEqual(job(labels: ["ubuntu-latest"]).machine, "GitHub-hosted")
        XCTAssertEqual(job(labels: ["macos-15"]).machine, "GitHub-hosted")
        XCTAssertEqual(job(runner: "nsc-runner-xyz", labels: ["namespace", "linux-x64"]).machine, "Namespace")
    }

    func testMachineEphemeralMacVMFallsBack() {
        // A macOS ephemeral VM registers a JIT runner with no host tag, and its
        // labels carry pulp-build-vm but not pulp-host-* — so it buckets as the
        // ephemeral VM rather than a specific Mac.
        XCTAssertEqual(job(runner: "ephr-1377-58",
                           labels: ["self-hosted", "macOS", "ARM64", "pulp-build", "pulp-build-vm"]).machine,
                       "Ephemeral VM")
    }

    func testMachineUnknownWhenNoSignal() {
        XCTAssertEqual(job(runner: nil, labels: nil).machine, "Unknown")
        XCTAssertEqual(job(runner: "", labels: []).machine, "Unknown")
    }

    func testRunnerLabelFallback() {
        XCTAssertEqual(job(labels: ["self-hosted", "pulp-build-vm"]).runnerLabel, "pulp-build-vm")
        XCTAssertEqual(job(runner: "ephr-9", labels: nil).runnerLabel, "ephr-9")
    }
}
