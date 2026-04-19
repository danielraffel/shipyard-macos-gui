# Architecture

## Framework choice — MenuBarExtra

This app is a pure SwiftUI `MenuBarExtra` scene. Minimum deployment: macOS 13
Ventura (where `MenuBarExtra` shipped).

`MenuBarExtra` is *not* Catalyst. Under the hood it uses AppKit's `NSStatusItem`
— the same thing a hand-rolled AppKit menu-bar app would use. The SwiftUI API
just hides the boilerplate. Behavior:

- No main window, no dock icon (`LSUIElement = true`).
- The menu bar icon hosts a label view (our `MenuBarLabelView`).
- `menuBarExtraStyle(.window)` gives us a popover that can host any SwiftUI
  view tree — not the restrictive NSMenu subset.

We explicitly do **not** use:

- `WindowGroup` — that's a document/main-window scene.
- `UIApplication` / UIKit symbols — those are Catalyst.
- `targetEnvironment(macCatalyst)` compile checks — we're native AppKit-backed.

## Data flow

```
 shipyard CLI                   app process
 ────────────                   ───────────
 shipyard watch --json ──── stdout ───▶  ShipyardCLIRunner (actor)
                                                │
                                                ▼
 shipyard doctor --json  ◀───── on-demand ───  AppStore  (@MainActor, @Observable)
                                                │
                                                ▼
 shipyard cloud retarget / add-lane             SwiftUI views
  (one-shot invocations)        ◀──────────── user actions
```

- **AppStore** is the single source of truth, runs on the main actor, owns
  published UI state, and persists settings through UserDefaults.
- **ShipyardCLIRunner** is an actor that spawns `shipyard watch --json --follow`
  and streams one line per NDJSON event. It respawns on EOF with a 2-second
  backoff so a transient CLI crash doesn't kill the observer.
- **One-shot subprocesses** (`doctor`, `retarget`, `add-lane`) run ad-hoc via
  a simple `Process` helper; no long-lived connection.

## Binary discovery

Checked in order, first hit wins:

1. `UserDefaults.standard.string(forKey: "cliBinaryPath")` — user override.
2. `/usr/local/bin/shipyard`
3. `/opt/homebrew/bin/shipyard`
4. `~/.local/bin/shipyard`

If none is found, `cliBinaryError` is surfaced in the UI and the Doctor + Ships
tabs show an actionable prompt.

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
