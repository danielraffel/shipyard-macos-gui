# Shipyard macOS

A native macOS menu-bar companion for [Shipyard](https://github.com/danielraffel/Shipyard)
— the cross-platform CI controller for AI agents.

The agent runs `shipyard ship`, the app reads `shipyard watch --json --follow`
and keeps a glanceable summary of every in-flight ship in your menu bar.

**Native Swift/SwiftUI — `MenuBarExtra`, no Catalyst, no Electron, no web tech.**

## Download

**[Latest signed & notarized DMG](https://github.com/danielraffel/shipyard-macos-gui/releases/latest/download/Shipyard.dmg)**

Requires macOS 13 Ventura or later. Drag the app from the DMG into
`/Applications` and launch.

## Status

Early skeleton. The plumbing (menu-bar icon, popover tabs, NDJSON subprocess,
settings, doctor pane) is wired up; the detailed interactive flows from the
[design prototype](../shipyard/macos-feature-ideas) are stubbed and ready to
extend.

## Requirements

- macOS 13 Ventura or later (`MenuBarExtra` availability)
- Xcode 16+ (built on Xcode 26.3)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- The `shipyard` CLI installed somewhere on your PATH
  (`/usr/local/bin/shipyard` or `/opt/homebrew/bin/shipyard` auto-discovered)

## Build & run

```bash
git clone git@github.com:danielraffel/shipyard-macos-gui.git
cd shipyard-macos-gui
./scripts/bootstrap.sh      # generates ShipyardMenuBar.xcodeproj via xcodegen
open ShipyardMenuBar.xcodeproj
#  …or:
./scripts/build.sh Release   # xcodebuild archive → build/ShipyardMenuBar-Release.xcarchive
```

Signing uses your Developer ID from the project settings. For unsigned local
debug runs, change `CODE_SIGN_STYLE` in `project.yml` to `Automatic` with no
team set, regenerate with `xcodegen generate`, and use a Debug build.

## Notarization

```bash
# One-time — store creds outside the repo:
cat > ~/.config/shipyard-macos-gui.env <<'EOF'
APPLE_ID=you@example.com
TEAM_ID=XXXXXXXXXX
APP_SPECIFIC_PASSWORD=abcd-efgh-ijkl-mnop
EOF
chmod 600 ~/.config/shipyard-macos-gui.env

./scripts/build.sh Release
./scripts/notarize.sh build/ShipyardMenuBar-Release.xcarchive/Products/Applications/Shipyard.app
```

## Release

The release flow is **tag-triggered and local** — no GitHub Actions,
no publishing on every commit. The stable download URL
(`releases/latest/download/Shipyard.dmg`) always resolves to the
newest release's asset.

```bash
# 1. Bump MARKETING_VERSION in project.yml (source of truth)
# 2. Commit the bump; push.
# 3. Tag and release:
git tag v1.0.0
git push --tags
./scripts/release.sh             # reads tag from HEAD
```

What `release.sh` does:

1. Validates the git tag matches `project.yml`'s `MARKETING_VERSION`
   and fails loudly on drift.
2. `./scripts/build.sh Release` — produces `build/ShipyardMenuBar-Release.xcarchive`.
3. `xcodebuild -exportArchive` with a Developer ID distribution
   `exportOptions.plist` — produces a signed, hardened, timestamped `.app`.
4. `./scripts/notarize.sh` — submits to Apple notary, waits, staples.
5. Verifies the `.app` is properly stapled.
6. `hdiutil create` → `dist/Shipyard.dmg` (stable filename, no version).
7. Staples and validates the DMG.
8. `gh release create / upload --clobber` — idempotent on re-runs.

Credentials (`APPLE_ID`, `TEAM_ID`, `APP_SPECIFIC_PASSWORD`) live in
`~/.config/shipyard-macos-gui.env` (gitignored). Add `--draft` to
`release.sh` for a dry-run that publishes as a draft:

```bash
./scripts/release.sh v0.0.0-dryrun --draft
```

## License

[MIT](LICENSE). © 2026 Generous Corp.

## Why native (not Catalyst)

- `MenuBarExtra` is pure SwiftUI on macOS 13+, backed by `NSStatusItem`.
- No `UIApplication`, no `targetEnvironment(macCatalyst)` — real AppKit host.
- Proper `LSUIElement = true` so no dock icon.
- Code signing via `Developer ID Application` + hardened runtime + timestamp.
- Sandbox disabled (the app spawns the `shipyard` CLI subprocess; sandbox would
  block that without a complex entitlement for each path).

Reference for what NOT to do: see [HomeKitMenu](https://github.com/danielraffel/HomeKitMenu)'s
use of `UIApplication.didBecomeActiveNotification` and
`#if targetEnvironment(macCatalyst)` — that's the Catalyst path this project
explicitly avoids.

## Project layout

```
shipyard-macos-gui/
├── project.yml                          # xcodegen spec (source of truth)
├── ShipyardMenuBar.xcodeproj/           # generated — do not edit by hand
├── Sources/ShipyardMenuBar/
│   ├── ShipyardMenuBarApp.swift         # @main, MenuBarExtra scene
│   ├── Models/
│   │   └── Models.swift                 # Ship, Target, Runner, status enums
│   ├── Services/
│   │   ├── AppStore.swift               # @Observable app state
│   │   └── ShipyardCLIRunner.swift      # NDJSON subprocess actor
│   └── Views/
│       ├── MenuBarLabelView.swift       # icon + badge
│       ├── PopoverView.swift            # tab host
│       ├── ShipsView.swift              # list of ships
│       ├── ShipCardView.swift           # one ship card
│       ├── TargetRowView.swift          # one target row
│       ├── DoctorView.swift             # shipyard doctor --json wrapper
│       └── SettingsView.swift           # prefs
├── Resources/
│   ├── Info.plist                       # generated by xcodegen
│   └── ShipyardMenuBar.entitlements
├── scripts/
│   ├── bootstrap.sh                     # xcodegen generate + signing check
│   ├── build.sh                         # xcodebuild archive
│   └── notarize.sh                      # notarytool submit + staple
└── docs/
    └── ARCHITECTURE.md                  # design notes
```

## Roadmap to shipped app (rough)

- [x] MenuBarExtra scaffolding, popover tabs, settings
- [x] CLI binary discovery + subprocess wrapper
- [x] `shipyard doctor --json` integration in Doctor pane
- [ ] NDJSON `shipyard watch --json --follow` integration — parse → Ship state
- [ ] Multi-worktree ship discovery via `shipyard ship-state list --json`
- [ ] Interactive runner picker + inline log pane per target row
- [ ] `cloud retarget` / `cloud add-lane` wired to one-click actions
- [ ] `auto-merge` toggle per PR
- [ ] Failure classification colors (INFRA/TIMEOUT/TEST) from #83
- [ ] Heartbeat stale marker from #84
- [ ] Advisory lane dim + tag from #87
- [ ] Resume prompt on wake (optional, default off)

## License

TBD.
