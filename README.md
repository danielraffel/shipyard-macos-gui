# Shipyard MenuBar for macOS

A native macOS menu-bar companion for [Shipyard](https://github.com/danielraffel/Shipyard) — the cross-platform CI controller.

## What it does

Shipyard itself runs in the terminal, and that's still the preferred way to
drive it. This app is a **quick glance** at what's happening without dropping
into a shell:

- See every in-flight PR's CI status in one popover — green / running / failed
  per platform.
- Click a job to **retarget** it to a different runner (GitHub-hosted →
  Namespace, or vice-versa) without editing workflow YAML.
- **Add a lane** (macOS / Linux / Windows / iOS / Android) to an in-flight PR
  without re-dispatching the whole matrix.
- Click straight through to the GitHub run, the PR, or logs.
- See active Namespace runner instances from `nsc list` without spending
  GitHub API quota.
- `shipyard doctor` output in a dedicated pane.
- Notifications on merge / fail / all-green.

It was my first test of [Claude Design](https://claude.ai/design) — built
on an airplane — so treat the polish accordingly.

## Screenshots

| Active PR | Retarget | Confirm before interrupting |
|---|---|---|
| ![Active PR](docs/screenshots/active-runner.png) | ![Retarget](docs/screenshots/retarget.png) | ![Confirm](docs/screenshots/confirm-interrupt.png) |

| Add a lane | Other checks |
|---|---|
| ![Add lane](docs/screenshots/add-lane.png) | ![Other checks](docs/screenshots/other-checks.png) |

## Live mode (optional)

Sub-second CI status via webhooks instead of polling — no GitHub API
rate limits. Requires [Tailscale](https://tailscale.com) with
[Funnel](https://tailscale.com/kb/1223/funnel) enabled on your tailnet.
When enabled, Shipyard sets up the tunnel and registers webhooks
automatically; disabling reverses both.

Default is **Auto** (live when Tailscale is ready, polling at 60s when
it isn't). Set **On** to require live with a warning when unavailable,
or **Off** to force polling. Webhook events route through Tailscale's
edge directly to your Mac — no Shipyard-operated backend in between.

## Download

**[Latest signed & notarized DMG](https://github.com/danielraffel/shipyard-macos-gui/releases/latest/download/Shipyard.dmg)**

Requires macOS 13 Ventura or later. Drag from the DMG into `/Applications` and launch. The app lives in the menu bar — no dock icon.

Requires the `shipyard` CLI. The app uses the selected path from
Settings when provided, otherwise it auto-discovers `/usr/local/bin`,
`/opt/homebrew/bin`, `~/.pulp/bin`, then the canonical Rust install at
`~/.local/bin/shipyard`.

When the selected CLI supports `shipyard --json paths`, the app derives
the daemon socket, pid file, and daemon directory from that CLI so
side-by-side validation builds and production installs do not collide.
Older CLIs fall back to the legacy
`~/Library/Application Support/shipyard/daemon` socket.

The Tailscale App Store build is supported for live mode; the app probes
`/Applications/Tailscale.app/Contents/MacOS/Tailscale` before Homebrew
or system PATH locations.

## Namespace instances

When `nsc` is installed and authenticated, the Runners view shows raw
Namespace instances every 30 seconds via `nsc list --all -o json`. These
rows are runner VMs, not PRs or GitHub jobs. The UI mirrors Namespace Cloud's
shape vocabulary where `nsc` exposes it: active instance, instance ID, platform
(`mac/silicon`, `linux/amd64`, `win/amd64`), and size (`6x14`, `4x8`).
Expanding a row fetches `nsc describe <instance> -o json` for container
readiness when Namespace still has detail for that ephemeral instance, and
provides copyable `nsc describe`, `nsc top`, and `nsc logs` commands.

The app shows every active instance returned by `nsc list`. It does not merge
or hide rows against GitHub Actions because `nsc` does not expose stable job
IDs locally; instead, the Runners view keeps Namespace instances in their own
infrastructure section so the UI does not imply a PR/job mapping it cannot
prove. Future improvements are waiting on `nsc` or an API to expose GitHub
run/job IDs, runner assignment state, per-instance web/log URLs, and lifecycle
events.

## Runners view sections

The Runners view separates three different data sources so rows do not
overlap or imply more certainty than the app has:

- **Tracked PRs** are Shipyard-managed work from local
  `shipyard ship-state list`. These are the only rows rendered as PR cards
  with Shipyard actions such as retargeting or adding lanes. They are grouped
  by repo, with optional worktree sub-grouping.
- **GitHub Actions not tracked by Shipyard** are workflow runs from the
  existing `gh run list` cache that do not match local Shipyard state by
  branch or SHA. The GUI intentionally does not call `gh pr list`; GitHub API
  quota is reserved for CI status. These rows may be PR-related, main/tag
  workflows, manual dispatches, or scheduled jobs, so they are rendered as
  Actions runs, not PR cards.
- **Namespace instances** are raw runner VMs from `nsc list`. They are
  infrastructure, not PRs or jobs.

## Build locally

```bash
git clone git@github.com:danielraffel/shipyard-macos-gui.git
cd shipyard-macos-gui
brew install xcodegen
./scripts/bootstrap.sh          # generates ShipyardMenuBar.xcodeproj
open ShipyardMenuBar.xcodeproj  # or: ./scripts/build.sh Release
```

For unsigned local debug, set `CODE_SIGN_STYLE: Automatic` with no team in `project.yml`, regenerate with `xcodegen generate`, and use a Debug build.

## Release

Tag-triggered, local-only — no GitHub Actions. The stable download URL (`releases/latest/download/Shipyard.dmg`) always points at the newest release.

If you're working with Claude Code, say **"push a build"** and it'll handle the full flow (see `CLAUDE.md`). Manually:

```bash
# 1. Bump MARKETING_VERSION in project.yml, commit.
git tag v1.0.0
git push --tags
./scripts/release.sh            # reads tag from HEAD
```

`release.sh` validates the tag against `project.yml`, archives, signs, notarizes the `.app` and the DMG, staples both, and publishes via `gh release`. Idempotent on re-runs (`--clobber`).

Credentials live in `~/.config/shipyard-macos-gui.env` (gitignored):

```
APPLE_ID=you@example.com
TEAM_ID=XXXXXXXXXX
APP_SPECIFIC_PASSWORD=abcd-efgh-ijkl-mnop
```

Add `--draft` for a dry-run that publishes as a draft.

## Project layout

```
shipyard-macos-gui/
├── project.yml                     # xcodegen spec (source of truth)
├── CLAUDE.md                       # agent shortcuts: "push a build" etc.
├── Sources/ShipyardMenuBar/
│   ├── ShipyardMenuBarApp.swift    # @main
│   ├── Models/Models.swift         # Ship, Target, Runner, status enums
│   ├── Services/
│   │   ├── AppStore.swift          # central @MainActor state
│   │   ├── StatusItemController.swift  # NSStatusItem + NSPopover
│   │   ├── ShipStatePoller.swift   # ship-state list via daemon IPC/CLI
│   │   ├── ShipyardCLIRunner.swift # NDJSON subprocess actor
│   │   └── LiveMode/DaemonClient.swift # daemon IPC + live webhook bridge
│   └── Views/                      # SwiftUI views
├── scripts/
│   ├── bootstrap.sh                # xcodegen generate + signing check
│   ├── build.sh                    # xcodebuild archive
│   ├── notarize.sh                 # notarytool submit + staple
│   └── release.sh                  # full tag → DMG → release pipeline
└── docs/ARCHITECTURE.md
```

## License

[MIT](LICENSE).
