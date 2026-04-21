# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What is this

Native macOS menu-bar companion for [Shipyard](https://github.com/danielraffel/Shipyard) — see `README.md` for the product pitch.

Swift + SwiftUI. Built via **xcodegen** from `project.yml`. Signed with the
user's Developer ID and distributed as a notarized DMG via a **tag-triggered,
local-only release pipeline** (`scripts/release.sh`).

## Version is single-source — `project.yml`

Only `project.yml` carries the version:
- `MARKETING_VERSION` (semver like `0.1.0`)
- `CURRENT_PROJECT_VERSION` (monotonic integer build number)

`release.sh` hard-fails if the git tag doesn't match `MARKETING_VERSION`. Don't
keep version strings anywhere else.

## User shortcuts — what they mean, what to do

| User says | You do |
|---|---|
| "push a build", "ship it", "release this", "cut a release" | Full tag → release flow below (default = patch bump). |
| "push a major build", "major release" | Same flow, but bump major. |
| "push a minor build", "minor release" | Same flow, but bump minor. |
| "show me the notes" / "preview release notes" | Generate notes via `shipyard changelog regenerate --release-notes v<next>` (or git log since last tag). Show inline. Don't tag, don't push, don't release. |
| "rebuild and re-upload" | Re-run `./scripts/release.sh` with the existing tag. It's idempotent — re-uploads the DMG with `--clobber`. |

## "Push a build" — the exact sequence

Default interpretation is **patch bump**. Ask only if ambiguous.

1. Read current `MARKETING_VERSION` from `project.yml` (awk the first `MARKETING_VERSION:` line, strip quotes).
2. Compute next version (default: bump patch — e.g. `0.1.0` → `0.1.1`).
3. Edit `project.yml`:
   - `MARKETING_VERSION: "<new>"`
   - Increment `CURRENT_PROJECT_VERSION` by 1.
4. Commit with message `chore: bump to v<new>`.
5. Create the tag: `git tag v<new>`.
6. Push commits + tag: `git push && git push --tags`.
7. Run `./scripts/release.sh` — it handles build, notarize, DMG, GitHub release.
8. Report back: tag URL + stable URL (`https://github.com/danielraffel/shipyard-macos-gui/releases/latest/download/Shipyard.dmg`).

If `./scripts/release.sh` fails, surface the last error. Don't retry blindly; ask the user.

## Release notes

`release.sh` uses `shipyard changelog regenerate --release-notes <tag>` when the
shipyard CLI is on PATH (the user installs it at `~/.pulp/bin/shipyard`).
Falls back to `gh release create --generate-notes` if the CLI isn't available.

This repo is a deliberate test bed for shipyard's changelog automation —
dogfooding the feature we built in the main shipyard repo. See
`.shipyard/config.toml` for the opt-in config.

## Things to NEVER do

- Don't create a GitHub Actions workflow for releases. The release path is explicitly local.
- Don't version the DMG filename. It's always `Shipyard.dmg` so the `/releases/latest/download/Shipyard.dmg` stable URL works.
- Don't push to `main` without a PR unless the user explicitly says so. (Trivial commits during an active session are OK.)
- Don't echo Apple credentials. They live in `~/.config/shipyard-macos-gui.env` and flow into `release.sh` silently.
- Don't edit `ShipyardMenuBar.xcodeproj/` — it's generated. Edit `project.yml` and re-run `xcodegen generate`.

## Local dev loop

```bash
./scripts/bootstrap.sh       # xcodegen generate + sanity check
./scripts/build.sh Release   # archive (no DMG, no release)
```

For a quick Debug run: `xcodebuild … build` then `open build/.../Shipyard.app`.

## What the menu-bar app shows

See `Sources/ShipyardMenuBar/` for the full model. Key data sources:

- `shipyard --json ship-state list` — local ship-state entries
- `gh run list --repo <r> --json …` — GitHub Actions runs on those PR branches
- `gh run view <id> --json jobs` — matrix jobs inside each workflow (where platform labels live)
- `gh pr view <n> --json state,mergedAt,closedAt` — open/merged/closed so stale state gets the right pill

See `docs/ARCHITECTURE.md` for the full data flow.
