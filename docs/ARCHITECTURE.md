# Architecture

## Framework choice — MenuBarExtra

This app is a pure SwiftUI `MenuBarExtra` scene. Minimum deployment: macOS 13
Ventura (where `MenuBarExtra` shipped).

`MenuBarExtra` is *not* Catalyst. Under the hood it uses AppKit's `NSStatusItem`
— the same thing a hand-rolled AppKit menu-bar app would use. The SwiftUI API
just hides the boilerplate. Behavior:

- No main window, no dock icon (`LSUIElement = true`).
- The menu bar icon + popover are hand-rolled via `StatusItemController`
  (raw `NSStatusItem` + `NSPopover`). `MenuBarExtra`'s template-image
  path was unreliable on recent macOS builds (icon rendered as a solid
  black circle), so we manage the status item ourselves.

We explicitly do **not** use:

- `WindowGroup` — that's a document/main-window scene.
- `UIApplication` / UIKit symbols — those are Catalyst.
- `targetEnvironment(macCatalyst)` compile checks — we're native AppKit-backed.

## Data flow

```
 shipyard CLI / daemon                 app process
 ─────────────────────                 ───────────
 shipyard --json ship-state list  ─▶  ShipyardPipeline
 daemon IPC ship-state-list       ─▶  ShipStateListPoller
 daemon IPC subscribe/events      ─▶  DaemonClient
 nsc list/describe JSON           ─▶  NamespaceActivityPoller
 shipyard doctor --json           ◀─  AppStore  (@MainActor, ObservableObject)
 shipyard cloud retarget/add-lane ◀─  SwiftUI views
```

- **AppStore** is the single source of truth, runs on the main actor, owns
  published UI state, and persists settings through UserDefaults.
- **ShipyardPipeline** polls `shipyard --json ship-state list` every 7 seconds
  for the authoritative snapshot. It emits an immediate empty snapshot at
  startup so the UI does not stay stuck on a spinner while the CLI warms up.
- **ShipStateListPoller** prefers the daemon IPC `ship-state-list` request
  because the daemon serves the same JSON from memory in milliseconds. If the
  daemon socket is unavailable or too old, it falls back to the CLI subprocess.
- **DaemonClient** owns live mode: it can start `shipyard daemon`, subscribe to
  the daemon socket for webhook events, and mirror daemon status/tunnel state
  into the UI.
- **ShipyardCLIRunner** remains a long-lived NDJSON subprocess wrapper for
  command paths that need `shipyard watch --json --follow`, but the main ship
  list is no longer watch-first.
- **One-shot subprocesses** (`doctor`, `retarget`, `add-lane`) run ad-hoc via
  a simple `Process` helper; no long-lived connection.
- **NamespaceActivityPoller** samples `nsc list --all -o json` every 30 seconds
  for raw Namespace runner instances and lazily runs `nsc describe <id> -o json`
  when a row is expanded. This does not spend GitHub API quota.
- **GitHub Actions not tracked by Shipyard** is derived from the existing
  `gh run list` cache. The GUI intentionally does not call `gh pr list`
  automatically, so this view adds no extra GitHub API calls beyond the
  Actions polling already needed for CI status.

## Runners View Semantics

The Runners view keeps three concepts separate:

- Tracked PR cards come only from local Shipyard `ship-state` and are the
  only rows with Shipyard actions.
- GitHub Actions not tracked by Shipyard are workflow runs from `gh run list`
  that do not match local Shipyard state by branch or SHA. They may be
  PR-related, main/tag workflows, manual dispatches, or scheduled jobs; without
  `gh pr list`, the app does not know enough to render them as PR cards.
- Namespace rows are raw runner instances from `nsc list`, not PRs or jobs.

## Namespace visibility

Namespace data is intentionally presented as instance-level infrastructure
state, not as PR/job state. A GitHub PR can create multiple workflow runs, each
run can create multiple jobs, and Namespace can provision runner instances that
are not yet assigned to a job. Until `nsc` exposes stable GitHub run/job IDs,
the GUI does not attempt exact merging with GitHub job rows; it shows every
active `nsc list` instance in a separate infrastructure section.

The row chrome intentionally follows Namespace Cloud's instance vocabulary only
for fields returned by `nsc list`: active instance, ID, platform, and size. The
GUI does not infer workflow names or "no job yet" because those fields are not
exposed by `nsc list`. If an already-cached GitHub job reports
`runner_name: nsc-runner-<instance-id>`, the GUI joins that job to the
Namespace row and can derive the Namespace Cloud URL as
`https://cloud.namespace.so/<workspace>/actions/job/<github-job-id>`. The
workspace slug comes from `nsc workspace describe -o json`. This opportunistic
join adds no `gh pr list` calls and no broad GitHub scans.

Future Namespace UX depends on richer `nsc` or API fields:

- GitHub run ID and job ID for exact dedupe and direct github.com links.
- Runner assignment state so idle, queued, and busy instances render distinctly.
- Stable per-instance web or log URLs for one-click drill-in from the menu bar.
- Lifecycle events so Namespace rows can update live instead of every 30 seconds.

## Binary discovery

Checked in order, first hit wins:

1. `UserDefaults.standard.string(forKey: "cliBinaryPath")` — user override.
2. `/usr/local/bin/shipyard`
3. `/opt/homebrew/bin/shipyard`
4. `~/.pulp/bin/shipyard`
5. `~/.local/bin/shipyard`

If none is found, `cliBinaryError` is surfaced in the UI and the Doctor + Ships
tabs show an actionable prompt.

The same order is used by `DaemonClient` when spawning the daemon, so Settings
does not accidentally point normal CLI calls at one binary while live mode
starts another.

## Daemon runtime paths

Rust Shipyard exposes `shipyard --json paths`. When available, the GUI uses it
to derive:

- `daemon_dir`
- `daemon_socket`
- `daemon_pid_file`

This is important for side-by-side validation and future compatibility because
the selected CLI owns its own runtime layout. Older Python CLIs without
`paths` fall back to:

```text
~/Library/Application Support/shipyard/daemon/daemon.sock
```

## Tailscale probing

Live mode uses Tailscale Funnel through the Shipyard daemon. The GUI's
Tailscale probe checks these binaries in order:

1. `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
2. `/opt/homebrew/bin/tailscale`
3. `/usr/local/bin/tailscale`
4. `/usr/bin/tailscale`

The App Store Tailscale build is intentionally first because it may be present
without a working `tailscale` PATH shim. In Auto/On live mode the daemon is
still authoritative: if the GUI probe is uncertain, the GUI attempts daemon
connection and surfaces the daemon's real failure reason.

GitHub webhook registration is allowed to fail soft when the `gh` token lacks
`admin:repo_hook`. That state is not a daemon crash: the GUI pauses GitHub API
polling, shows a hook-authorization warning, and exposes a copy button for:

```bash
gh auth refresh -h github.com -s admin:repo_hook
```

## Sandbox + entitlements

Sandbox is **off** (`com.apple.security.app-sandbox = false`) because the app
spawns arbitrary CLI subprocesses at user-chosen paths. A sandboxed version
would need:

- A per-path entitlement for the user's `shipyard` binary, or
- A user-selected file via `NSOpenPanel` stored as a security-scoped bookmark.

Revisit if we ever ship through the App Store (which we won't, since we
distribute via Developer ID + notarization).

## Signing

`project.yml` hard-codes `DEVELOPMENT_TEAM = 95CX6P84C4` and
`CODE_SIGN_IDENTITY = Developer ID Application: Daniel Raffel (95CX6P84C4)`.
Hardened runtime is on (required for notarization). The entitlements file
does not grant any of the hardened-runtime exceptions.

## NDJSON schema consumed

From the Shipyard CLI (see `shipyard/skills/ci/SKILL.md` in the main repo):

```
{
  "event": "update",
  "pr": 218,
  "head_sha": "...",
  "attempt": 1,
  "evidence": {"macos-arm64": "pass", ...},
  "dispatched_runs": [
    {
      "target": "Windows-x86_64",
      "provider": "github-hosted",
      "run_id": "18392847",
      "status": "running",
      "started_at": "...",
      "updated_at": "...",
      "attempt": 1,
      "last_heartbeat_at": "...",
      "phase": "build",
      "elapsed_seconds": 45,
      "required": true
    }
  ],
  "updated_at": "..."
}
```

Terminal events: `pr-not-found`, `state-archived`, `no-active-ship`.

## Why not an Xcode project file in git?

`.xcodeproj` is a generated artifact. We commit `project.yml` (xcodegen's
input) and let every clone regenerate the project. Avoids merge conflicts in
`project.pbxproj` and makes build settings reviewable as a diff.
