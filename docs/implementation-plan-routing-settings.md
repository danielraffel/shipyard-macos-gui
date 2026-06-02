# Implementation plan: Routing & Runners settings (aligned)

Status: **reviewed — ready to build (awaiting owner go)** · Created 2026-06-02
Source proposal: [`proposal-routing-settings.md`](./proposal-routing-settings.md)
Review trail: RepoPrompt two-repo plan → Codex review #1 (4 blockers) → aligned →
review pass A (RepoPrompt oracle: 3 P1 + nice-to-haves) → review pass B (Codex: 5/6
PASS, 2 concerns). All blocking items folded in. Two residual concerns from pass B
(no-root slug collision/transition §3b; `repo_root` data path through
`ShipExecutionRequest`/queue snapshots §2d) are now resolved in this doc.

> This is the implementation spec. Do **not** start coding from it until the
> owner explicitly says go. It spans two repos: **Shipyard** (Rust CLI) and
> **shipyard-macos-gui** (Swift/SwiftUI). Build Shipyard changes first; the GUI
> depends on them.

## 0. Locked decisions (from the proposal)

- **Per-machine only** — GUI/CLI write `.shipyard.local/config.toml`, never the
  committed `.shipyard/config.toml`.
- **Per-repo, with a repo picker** — the GUI is a global menu-bar app watching
  many repos via ship-state.
- **GitHub repo Variables stay CLI-only** (e.g. `PULP_LOCAL_MACOS_RUNS_ON_JSON`)
  — never edited from the GUI.
- **Descriptions lead, names follow** — radio list; labels come from each
  profile's `description` field.
- Canonical profiles: `local` / `normal` / `cloud` / `full` (defined per consuming
  repo, not in Shipyard itself).

## 1. The cross-repo interface contract (the seam)

The GUI depends on three additive, backward-compatible CLI behaviors. Lock these
shapes first; both sides build against them.

### 1a. `shipyard --json config profiles` (extended — additive)
Run with cwd = repo root. Adds provenance fields:
```json
{
  "schema_version": 1,
  "command": "config.profiles",
  "profiles": [
    { "name": "normal", "active": true, "targets": ["mac","ubuntu-cloud","windows-cloud"],
      "description": "Mac does macOS; Linux/Windows run in cloud.",
      "focus_platforms": [], "advisory_platforms": [] }
  ],
  "active": "normal",
  "active_source": "local",          // "local" | "tracked" | "global" | "none"
  "active_path": "/repo/.shipyard.local/config.toml",
  "local_overlay_source": "direct",  // "direct" | "worktree_fallback" | "none"
  "local_overlay_path": "/repo/.shipyard.local/config.toml",
  "tracked_config_path": "/repo/.shipyard/config.toml"
}
```
Presence of `active_source` is the GUI's **capability signal** (see 3d).

### 1b. `shipyard --json config use <profile> --local` (new flag — additive)
Run with cwd = repo root. Writes `[project].profile` to the **direct**
`.shipyard.local/config.toml` for this checkout; never touches tracked config.
```json
{ "schema_version": 1, "command": "config.use", "profile": "normal",
  "scope": "local", "path": "/repo/.shipyard.local/config.toml", "active_source": "local" }
```
Default `config use <profile>` (no `--local`) keeps today's tracked-write behavior.

### 1c. `shipyard --json ship-state list` (extended — additive)
Each record gains `repo_root` (absolute path to the checkout containing
`.shipyard/config.toml`). Old records / old CLIs: field absent → GUI treats as
unknown and falls back to the checkout picker.

## 2. Shipyard (Rust CLI) changes

### 2a. `config use --local` — `src/app/cli.rs`, `src/app/config_cmd.rs`
- Add `#[arg(long)] local: bool` to `ConfigCommand::Use`.
- Thread a `ConfigUseScope { Tracked, Local }` into `config_use`.
- Write-path resolution:
  - `Tracked` → `<project_dir>/config.toml` (unchanged default).
  - `Local` → if `local_overlay_source == Direct`, write `<local_dir>/config.toml`;
    else write `cwd/<local_overlay_dir_name>/config.toml` (the current checkout's
    own overlay — **never** a borrowed worktree-fallback overlay).
- Create the overlay dir if needed; reuse `init_config.rs`'s gitignore helper to
  ensure `.shipyard.local/` is ignored (promote it to a shared fn, no behavior change).
- Generalize `rewrite_profile_in_config` to create-or-update a TOML file.

### 2b. Active-source provenance — **resolves Codex BLOCKER #1** (revised after review A)
The merged config can't tell you which layer supplied `project.profile`. Strategy
that keeps CLI reporting consistent with runtime:
1. Compute the **effective** active profile exactly as today — merged
   `project.profile`, non-empty (`active_profile(config)` in `config_cmd.rs`). The
   reported `active` MUST be this value so CLI output never disagrees with runtime.
2. Determine its **source** by re-reading each layer's raw `[project].profile` and
   finding the highest-precedence layer whose value equals that effective value.
   Precedence: local → tracked → global. If effective active is `None`,
   `active_source = "none"`.
- **Reads** use paths on `LoadedConfig` (review A confirmed these exist): global
  `global_dir/config.toml`, tracked `project_dir/config.toml`, resolved local
  overlay `local_dir/config.toml`, plus `local_overlay_source`.
- Add a contained `resolve_active_profile_provenance(&LoadedConfig)`; do not thread
  provenance through the merge. Whatever builds the JSON `active`/per-row `active`
  must use this same effective value (not a second, divergent computation).

### 2c. Empty-string / clear semantics — **revised after review A**
Review A correction: because `deep_merge` overwrites scalars and `active_profile`
filters empties, a local `profile = ""` overwrites tracked to `""` → **no active
profile** (it does NOT silently fall through to tracked). To avoid that footgun:
- The GUI only ever **sets a valid profile name**; it never writes `""`.
- "Clear local override" is **out of scope** this slice — it would have to *remove*
  the `[project].profile` key (not write empty); track as a future
  `config use --local --clear`.
- So empty and absent both mean "no active selection," matching current behavior.

### 2d. `repo_root` on ship-state — `src/ship_state.rs`, `src/ship.rs`, `src/app/ship_state_cmd.rs`
- Add persisted `repo_root: String` (serde default `""` for old records; do **not**
  add `deny_unknown_fields` anywhere on these structs).
- Set it at ship-state creation from the absolute repo root (derive from
  `LoadedConfig.project_dir` → parent that holds `.shipyard/`).
- Serialization carries it into `ship-state list --json` automatically.
- **Thread the value through the full creation path (review B / Codex CP6):**
  `ShipState::new` has no `repo_root` param today, and `ShipExecutionRequest` carries
  no root — so add `repo_root` to `ShipExecutionRequest`, populate it where the
  request is built (from `LoadedConfig.project_dir`), and pass it into `ShipState::new`.
  **Also add it to the queued-request snapshot** (`src/queue_request.rs`
  serialize/restore) so a queued or **resumed** ship preserves `repo_root` instead of
  losing it. Default missing → `""` on restore.

### 2e. Tests (required, not "if practical") — `src/app.rs` + unit
- `config use` default still rewrites tracked config (regression guard).
- `config use --local` creates `.shipyard.local/config.toml` with `[project].profile`
  AND leaves `.shipyard/config.toml` byte-unchanged. **(Acceptance test — central locked decision.)**
- `config profiles --json` reports `active_source` = local / tracked / global / none across fixtures.
- **Worktree-fallback write** (promoted to required): when the read borrowed a
  worktree-fallback overlay, `--local` writes the current checkout's own
  `.shipyard.local`, not the borrowed one.
- ship-state: new CLI decodes an old record (missing `repo_root`) → `""`; round-trips new field.

### 2f. Docs — `docs/profiles.md`, `docs/cli-reference.md`, `commands/config.md`
- Document `config use` (tracked) vs `config use --local` (per-machine overlay).
- Canonical `local`/`normal`/`cloud`/`full` examples + fallback semantics.
- **Explicit note: GitHub repo Variables (routing for everyone's CI) remain
  CLI/`gh`-only and are intentionally not GUI-editable** (preserves the
  blast-radius boundary). Replace stale "no config subcommand yet" text.

## 3. shipyard-macos-gui (Swift) changes

### 3a. Models — `Models/RoutingModels.swift` (new)
`RoutingProfile`, `RoutingProfilesSnapshot` (incl. `activeSource`, `activePath`,
`localOverlaySource`...), `RoutingRepository`, source enums. Decoder tolerates
old CLI (missing `active_source` → `.unknown`; missing `description` → canonical
fallback label: local→"Just my Mac", normal→"Mac + cloud", cloud→"Everything on
cloud", full→"Mac + local VMs").

### 3b. Repo identity & overrides — **resolves Codex BLOCKER #2 + #3**
- **Stable `RoutingRepository.id`:** rooted entry → `id = repoRoot` (absolute path,
  unique per checkout). No-root entry → `id = "noroot:" + repo`. All of
  `selectedRoutingRepositoryID`, per-repo task/generation maps, and overrides key
  on this `id` — **never** on the bare slug.
- **Checkout overrides** persisted as `[routingRepoID → repoRoot]` keyed by the
  **stable** `id`. **The id never changes (review A):** a `noroot:<slug>` entry
  KEEPS that id after a checkout is picked — it just gains an effective `repoRoot`
  (the override) and `source = .userOverride`. It does **not** migrate to a path id.
  A rooted (path-id) entry only ever originates from an authoritative ship-state
  `repo_root`. If ship-state later reports a root for that slug, prefer the rooted
  entry and hide the `noroot:` override entry (its override may be dropped). This
  keeps `selectedRoutingRepositoryID`, task/generation maps, and overrides stable
  across a checkout pick. A slug with multiple ship-state roots already yields
  multiple rooted entries; the picker subtitle disambiguates by path.
- **Collision + transition (review B / Codex CP4):** a no-root slug yields exactly
  **one** picker entry (`noroot:<slug>`) and accepts **one** checkout override; we do
  not try to represent multiple un-rooted checkouts of the same slug (a second
  checkout only appears once ship-state reports it as a distinct rooted entry). When a
  rooted ship-state entry later supersedes a `noroot:<slug>` override, **migrate**: if
  `selectedRoutingRepositoryID == "noroot:<slug>"`, re-point it to the new rooted id;
  then drop the now-moot override and the `noroot:<slug>` per-repo state/task/generation
  entries (explicit cleanup, no orphaned keys).

### 3c. Subprocess runner — `Services/ShipyardCommandRunner.swift` (new)
cwd-aware one-shot runner (binary, args, `currentDirectoryPath`, timeout,
cancellation) using `ShipyardProcessEnvironment.configure`. **Must carry forward
the existing drain-before-wait behavior** (read stdout/stderr concurrently before
`waitUntilExit`) so larger JSON can't deadlock — **resolves Codex nice-to-have**.
On timeout or Task cancellation, **terminate the child process** (SIGTERM, brief
wait, then SIGKILL) so a cancelled Swift Task never leaves a stray `shipyard`
running (review A).

### 3d. Capability gate — **resolves Codex BLOCKER #4** (probe-first, per review A)
Probe capability rather than trust a version string (handles dev / pre-release /
`v`-prefixed builds):
- **read-capability** = `config profiles --json` includes `active_source`.
- **write-capability** = `shipyard config use --help` lists `--local`.
Both must pass to enable writes. `shipyard --version` is used only as a
**user-facing hint** inside the update message, never as the hard gate. If a probe
fails → routing stays **read-only** with "Update Shipyard to enable switching"
shown *before* any save attempt (not after a failed write).

### 3e. Service + AppStore — `Services/RoutingProfilesService.swift` (new), `AppStore.swift`
- Service: `fetchProfiles(binary, repoRoot)`, `useProfileLocally(...)` →
  `config use ... --local` then re-fetch to confirm. Surfaces stderr-first errors;
  old-CLI `--local` rejection → "update Shipyard" message.
- AppStore: routing repo discovery from ship-state `repo_root` (validate the path
  exists AND contains `.shipyard/config.toml`, else treat as no-root —
  **resolves Codex nice-to-have**); per-repo `RoutingState`; selected repo +
  overrides persisted; per-repo generation/cancel to drop stale/out-of-order
  results; cancel routing tasks in `shutdown()`. No optimistic active change —
  update only after confirmed re-fetch.
- **Persist last-seen routing repos/roots** (review A): `knownRepos` is session-only
  today, so after a restart with no active ship-state the picker would be empty even
  though the user configured a checkout. Persist a small `routingLastSeenRepoRoots`
  registry in `UserDefaults` so the Routing picker survives restarts.

### 3f. UI — `Views/SettingsView.swift` (Routing section, after `cliSection`)
Repo picker + description-first radio rows (description is the label, profile name
muted trailing tag, targets summary as subtitle). States: no-CLI / no-repos /
no-checkout (→ "Choose Checkout…", validates `.shipyard/config.toml` present) /
loading / no-profiles / loaded / saving / error. Footer: "Stored per-machine in
`.shipyard.local`. Won't change CI for collaborators." Phase 1 rows disabled
(read-only), Phase 2 selectable.

### 3g. Tests — `Tests/ShipyardMenuBarTests/RoutingProfilesTests.swift` (new)
Decode new + old (`active_source`-less) envelopes; canonical fallback labels;
no-profiles; fake-CLI service test asserting cwd + `--local` invocation;
capability-gate decisions.

## 4. Phasing / implementation order

1. **Shipyard CLI**: `--local` flag → local write path (+ worktree rule) →
   active-source provenance → `config profiles`/`config use` JSON → `repo_root`
   on ship-state → tests → docs.
2. **GUI Phase 1 (read-only)**: models + decode tests → cwd runner → service →
   ship-state `repo_root` ingest → AppStore routing discovery + capability gate →
   Settings Routing section showing active profile + source, rows disabled.
3. **GUI Phase 2 (writable)**: enable selection → `config use --local` → confirmed
   re-fetch → saving/error states.
4. **E2E acceptance**: with new CLI — selecting a profile creates
   `.shipyard.local/config.toml`, `.shipyard/config.toml` unchanged, `active_source`
   becomes `local`; with old CLI — read-only degrades, write is gated off with an
   update prompt.

## 5. Deferred (explicitly out of scope this slice)

Menu-bar quick-switch; raw per-machine `[targets.mac] backend` / `host_class.cap`
editing; GitHub repo-Variable editing; a `config use --local --clear` command;
`targets list --json` enrichment in the routing UI.

## 6. Open questions for the owner

- Min Shipyard version constant for the capability gate — set once `config use
  --local` lands and is released.
- Where the canonical `local`/`normal`/`cloud`/`full` profiles get defined first
  (pulp's `.shipyard/config.toml`?) — needed to dogfood the GUI.
