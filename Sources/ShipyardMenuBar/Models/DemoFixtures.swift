import Foundation

/// Fixture ships that look like a busy fleet — useful for visual work
/// and for demoing the app without spinning up real PRs.
enum DemoFixtures {
    static var ships: [Ship] {
        [
            Ship(
                id: "demo-218",
                repo: "danielraffel/myapp",
                prNumber: 218,
                branch: "feature/oauth-flow",
                worktree: "~/dev/app-main",
                headSha: "a1b2c3d4e5f6",
                targets: [
                    Target(
                        name: "macOS-arm64",
                        status: .passed,
                        phase: .test,
                        elapsedSeconds: 252,
                        runner: Runner(provider: .local, label: "mac-mini-m4")
                    ),
                    Target(
                        name: "Linux-x86_64",
                        status: .running,
                        phase: .build,
                        heartbeatAgeSeconds: 12,
                        elapsedSeconds: 108,
                        runner: Runner(provider: .ssh, label: "ssh-linux1")
                    ),
                    Target(
                        name: "Windows-x86_64",
                        status: .pending,
                        runner: Runner(provider: .github, label: "github-hosted")
                    ),
                ],
                startedAt: Date().addingTimeInterval(-600)
            ),
            Ship(
                id: "demo-221",
                repo: "danielraffel/libcore",
                prNumber: 221,
                branch: "fix/memory-leak",
                worktree: "~/dev/app-wt1",
                headSha: "9f8e7d6c5b4a",
                targets: [
                    Target(name: "macOS-arm64", status: .passed, phase: .test, elapsedSeconds: 221),
                    Target(name: "Linux-x86_64", status: .passed, phase: .test, elapsedSeconds: 189),
                    Target(
                        name: "Windows-x86_64",
                        status: .failed,
                        phase: .test,
                        elapsedSeconds: 134,
                        failureClass: .test,
                        runner: Runner(provider: .github, label: "github-hosted")
                    ),
                ],
                startedAt: Date().addingTimeInterval(-1200)
            ),
            Ship(
                id: "demo-225",
                repo: "danielraffel/myapp",
                prNumber: 225,
                branch: "feature/dark-mode",
                worktree: "~/dev/app-wt2",
                headSha: "3c4d5e6f7a8b",
                targets: [
                    Target(
                        name: "macOS-arm64",
                        status: .running,
                        phase: .test,
                        heartbeatAgeSeconds: 5,
                        elapsedSeconds: 45,
                        runner: Runner(provider: .local, label: "mac-mini-m4")
                    ),
                    Target(
                        name: "Linux-x86_64",
                        status: .running,
                        phase: .build,
                        heartbeatAgeSeconds: 105,
                        elapsedSeconds: 120,
                        runner: Runner(provider: .ssh, label: "ssh-linux1")
                    ),
                    Target(
                        name: "Windows-x86_64",
                        status: .running,
                        phase: .configure,
                        heartbeatAgeSeconds: 2,
                        elapsedSeconds: 18,
                        runner: Runner(provider: .github, label: "github-hosted")
                    ),
                ],
                autoMerge: true,
                startedAt: Date().addingTimeInterval(-180)
            ),
            Ship(
                id: "demo-230",
                repo: "danielraffel/docs-site",
                prNumber: 230,
                branch: "fix/crash-on-wake",
                worktree: "~/dev/app-wt3",
                headSha: "b7c8d9e0f1a2",
                targets: [
                    Target(
                        name: "macOS-arm64",
                        status: .running,
                        phase: .build,
                        heartbeatAgeSeconds: 45,
                        elapsedSeconds: 110,
                        runner: Runner(provider: .local, label: "mac-mini-m4")
                    ),
                    Target(
                        name: "Linux-x86_64",
                        status: .failed,
                        phase: .build,
                        elapsedSeconds: 75,
                        failureClass: .infra,
                        runner: Runner(provider: .ssh, label: "ssh-linux1"),
                        advisory: true
                    ),
                ],
                startedAt: Date().addingTimeInterval(-300)
            ),
        ]
    }
}
