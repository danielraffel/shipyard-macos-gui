# Proposal: Routing & Runners settings in the menu-bar app

Status: **approved** (2026-06-02) — see [`implementation-plan-routing-settings.md`](./implementation-plan-routing-settings.md) for the build spec · Created 2026-06-02

Expose Shipyard's per-machine build/validation routing in the GUI so you can
switch *how this Mac validates a given repo* without hand-editing a TOML file —
e.g. "just my Mac" vs "Mac + cloud" vs "everything" — and switch it per repo as
you move between projects.

## Why

Today, changing where a repo's macOS validation runs (local self-hosted pool vs
GitHub-hosted cloud vs VMs) means editing `.shipyard/config.toml` /
`.shipyard.local/config.toml` by hand. The motivating case: a VM-only laptop
("blackbook") that can't build on its own host, so its `[targets.mac]` is set to
`backend = "cloud"` to dispatch to the pool. That's a fiddly file edit a GUI
toggle should own.

## The config-layer model (important — this is the "repo vs runner" answer)

Shipyard settings live at **four** layers with different blast radius. Getting
this right is what keeps the GUI safe:

| Layer | Where | Scope | Examples |
|---|---|---|---|
| GitHub repo Variables | on GitHub (`gh variable`) | **per-repo, affects everyone's CI** | `PULP_LOCAL_MACOS_RUNS_ON_JSON` |
| Tracked repo config | `.shipyard/config.toml` (committed) | **per-repo, shared with all clones** | targets, validation, merge reqs, **profiles** |
| Per-machine repo overlay | `.shipyard.local/config.toml` (gitignored) | **per-repo *and* per-machine** | `host_class.*` cap, `[targets.mac] backend` |
| Global config | `~/Library/Application Support/shipyard/config.toml` | **per-machine, all repos** | GitHub App auth token |

"How **my machine** builds **this repo**" = the per-machine overlay. "How the
repo's **required CI** routes for **everyone**" = the GitHub repo variable.
Different knobs — the GUI must not blur them.

## Decisions (locked 2026-06-02)

1. **Per-machine only.** The GUI writes the per-machine overlay
   (`.shipyard.local`), never the committed `.shipyard/config.toml`. Switching
   must not change CI for collaborators.
2. **Per-repo, with a repo picker.** The app is a global menu-bar app watching
   many repos (those with ship-state). Routing is per-repo, selected via a
   picker — *not* a single machine-wide default.
3. **GitHub repo Variables stay CLI-only** for now. Editing them changes
   everyone's CI (an admin action); the GUI does not expose them in this slice.
4. **Descriptions lead, names follow.** `local` / `normal` / `full` are fine as
   keys, but the UX surfaces the human description prominently. The name is
   secondary.

## The mechanism: Shipyard profiles

Shipyard already has the right primitive — **profiles** (`shipyard config
profiles`, `shipyard config use <name>`). A profile bundles which targets run +
how. Canonical set (descriptions are the point):

```toml
# .shipyard/config.toml  (defined once, per repo)
[profiles.local]   # just my Mac — macOS only, on your Mac. Fast, free, offline.
targets = ["mac"]
[profiles.normal]  # macOS on your Mac; Linux/Windows on GitHub-hosted cloud.
targets = ["mac", "ubuntu-cloud", "windows-cloud"]
[profiles.cloud]   # everything on cloud runners — NOTHING runs on your Mac.
targets = ["mac-cloud", "ubuntu-cloud", "windows-cloud"]
[profiles.full]    # full matrix on YOUR hardware: Mac + local Linux/Windows VMs,
                   # cloud only as an infra fallback when a VM is unreachable.
targets = ["mac", "ubuntu", "windows"]   # ubuntu/windows = ssh→local VM (+cloud fallback)
```

What each means in plain terms:
- **local** — only macOS, only on your Mac. No cross-platform, no network.
- **normal** — your Mac does macOS; Linux + Windows run on GitHub-hosted cloud.
- **cloud** — *every* platform on cloud runners; your Mac builds nothing. (Travel,
  Mac busy, or no local Linux/Windows VMs — e.g. the blackbook.)
- **full** — the whole matrix on your own hardware (Mac + local Linux/Windows
  VMs); cloud is touched **only** when a local VM is unreachable (infra
  fallback, not test-failure fallback). Requires those VMs to exist.

### Gap to close first (Shipyard CLI)

`shipyard config use` currently rewrites the **tracked** `.shipyard/config.toml`
(`[project] profile = "..."`), i.e. a committed, everyone change. For a
per-machine GUI switch we need the active selection stored in the **local
overlay**:

- **Add `shipyard config use <name> --local`** → writes the active-profile
  selection into `.shipyard.local/config.toml`, leaving the tracked config
  untouched. Config merge already overlays local on tracked, so the resolver
  honors it. This is the one required CLI change.

Everything else the GUI needs already exists: `config profiles --json` (list +
active), `config show --json` (effective config), `targets list --json`
(reachability).

## Fallback semantics

Two distinct kinds, easy to conflate:

1. **Target fallback chain (Shipyard, per-target).** When a target's primary
   backend is *unreachable* (SSH host down, VM asleep, no local toolchain),
   Shipyard tries the next entry in that target's `fallback = [...]` chain
   (e.g. boot the VM → cloud Namespace → GitHub-hosted). **Infra-unreachability
   only** — if the backend is reachable and the *tests* fail, that failure is
   authoritative; Shipyard does not retry elsewhere to "make it pass."
2. **Capacity overflow (workflow + repo variables).** Separate layer: when the
   local self-hosted pool is *busy* (running workers ≥
   `PULP_LOCAL_MAC_OVERFLOW_THRESHOLD`), build.yml's resolve-provider routes the
   leg to cloud instead of queuing. This is the repo-variable/CI layer
   (CLI-only per our decisions), not the per-machine shipyard target config —
   it's what sent the blackbook's run to GitHub-hosted when the Studio was busy.

How it maps to the profiles (each profile **bakes** its own fallback):
- **local** — no fallback by design (only your Mac). If the Mac is unavailable a
  locally-initiated ship just waits for it; there's nothing to fall back to.
- **normal** — Linux/Windows are already cloud; the mac leg *may* carry a cloud
  fallback so a build survives the Mac being down.
- **cloud** — destination is cloud; "fallback" is provider-level (Namespace →
  GitHub-hosted) if one cloud is drained.
- **full** — the headline fallback case: each local VM target chains to cloud
  when its VM is unreachable.

UX stance for this slice: profiles bake their own fallback and the GUI just
*explains* it in each option's description — no separate fallback editor.
A later enhancement worth considering for laptops: an explicit
**"Fall back to cloud if my Mac is unavailable"** checkbox (a per-target
fallback edit — part of the deferred raw-config layer).

## UX

A **Routing** section in Settings (and optionally a menu-bar quick-switch later).
Radio list, not a terse dropdown, so the **description is always visible**:

```
Routing
┌────────────────────────────────────────────────────┐
│ Repository:  [ danielraffel/pulp              ▾ ]   │  ← repos with ship-state
│                                                     │
│ How this Mac validates this repo                    │
│                                                     │
│  ◉  Just my Mac                                     │  ← description is the label
│       macOS only, on your Mac. Fast, free.   local  │  ← name is secondary
│                                                     │
│  ○  Mac + cloud                                     │
│       Mac does macOS; Linux/Windows cloud   normal  │
│                                                     │
│  ○  Everything on cloud                             │
│       Nothing runs on your Mac               cloud  │
│                                                     │
│  ○  Mac + local VMs                                 │
│       Full matrix on your hardware; cloud     full  │
│       only if a VM is down                          │
│                                                     │
│  ℹ Stored per-machine (.shipyard.local). Won't      │
│    change CI for collaborators.                     │
└────────────────────────────────────────────────────┘
```

- Options are populated from `config profiles --json` for the selected repo; the
  description text comes from each profile's `description` field (so the repo
  owns the wording, and the GUI stays generic).
- Empty state when a repo defines no profiles: "This repo has no Shipyard
  profiles yet — define them in `.shipyard/config.toml`. [docs]".
- Selecting an option calls `shipyard config use <name> --local` in that repo's
  working dir, then re-reads to confirm.

## Phasing

1. **Shipyard**: add `config use --local` (+ `config profiles --json` already
   exists). Define the `local`/`normal`/`full` profiles in consuming repos.
2. **GUI**: Routing section — repo picker + description-first radio list, backed
   by the two CLI calls. Read-only first (show active profile), then writable.
3. **Later (not this slice)**: menu-bar quick-switch; surfacing per-machine
   `[targets.mac] backend` and `host_class` cap directly; repo-variable editing
   (admin, fenced).

## Open / deferred

- Per-machine `[targets.mac] backend` and `host_class.cap` are also per-machine
  knobs but aren't profile-shaped; defer until profiles cover the common case.
- Repo Variables (`PULP_LOCAL_MACOS_RUNS_ON_JSON`) remain CLI/`gh`-only.
