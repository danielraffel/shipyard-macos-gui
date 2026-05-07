# Changelog

All notable changes to shipyard-macos-gui are documented here. Each entry links
to its [GitHub Release](https://github.com/danielraffel/shipyard-macos-gui/releases).

## Unreleased

- Pause GitHub API polling for every live-requested-but-not-live state, not only missing `admin:repo_hook`, so transient daemon/Tailscale failures cannot silently burn rate limit.

<a id="v0121"></a>
## [0.1.21] - 2026-05-06

- Pause GitHub API polling while live mode is blocked on `admin:repo_hook` authorization, instead of silently falling back to 60s polling and burning rate limit.

<a id="v0120"></a>
## [0.1.20] - 2026-05-06

- Refresh local daemon status after live-mode warm-up so the header switches to live once Tailscale Funnel is ready, even if the first socket status frame was inactive.

<a id="v0119"></a>
## [0.1.19] - 2026-05-06

- Keep live mode from sticking on "polling" when the Rust daemon emits an early no-tunnel status frame during Tailscale Funnel warm-up.

<a id="v0118"></a>
## [0.1.18] - 2026-05-06

- Remove stale merged PR rows immediately when the Rust Shipyard daemon archives local ship-state from `pull_request.closed` webhooks.
- Replace the PR-state fallback with the lower-cost GitHub REST pulls endpoint and a longer retry cooldown to avoid GraphQL pressure.
- Keep the release script from mutating `CHANGELOG.md` after a successful DMG publish.

<a id="v0117"></a>
## [0.1.17] - 2026-05-06

- Fix live-mode daemon launch against Rust Shipyard builds that require `SHIPYARD_RUST_ENABLE_TUNNEL`, while keeping compatibility with released `SHIPYARD_ENABLE_TUNNEL` builds.
- Verified a patched GUI launch subscribes to the daemon and brings up Tailscale Funnel instead of replacing it with an inactive polling daemon.

<a id="v0116"></a>
## [0.1.16] - 2026-05-05

- Fix Finder and login-item launches so Shipyard subprocesses see user CLI paths for `gh`, `nsc`, Homebrew, Tailscale, and `~/.local/bin`.
- Keep live-mode daemon startup, Doctor, GitHub polling, Namespace polling, and log helpers on the same augmented CLI environment.

<a id="v0115"></a>
## [0.1.15] - 2026-05-05

- Add GitHub webhook auth fallback UI that keeps polling and copies the `admin:repo_hook` remediation command.
- Enrich Namespace rows from live webhook job data without making extra API calls when the job event already has runner details.

<a id="v0114"></a>
## [0.1.14] - 2026-05-05

- Improve first-open responsiveness by deferring expensive GitHub enrichment and live-startup work until after the popover paints.
- Add Namespace instance visibility, GitHub Actions not tracked by Shipyard, and clearer runner-section documentation.

<a id="v0113"></a>
## [0.1.13] - 2026-05-05

- Fix live-mode daemon startup so the GUI enables Tailscale Funnel for Shipyard CLI daemons and recovers from stale `inactive` daemons left by v0.1.12.
- Bound daemon subprocesses and one-shot daemon IPC reads so launch cannot hang behind a stuck CLI process or non-responsive socket.

<a id="v0112"></a>
## [0.1.12] - 2026-05-05

- Fix live-update status during Shipyard daemon tunnel warmup so the menu bar does not fall back to "polling" before the daemon reports its Tailscale Funnel URL.
- Request daemon status before subscribing to live events, avoiding delayed status behind replayed event backlog.

<a id="v0111"></a>
## [0.1.11] - 2026-05-04

- ui: render PR numbers without thousands separators ([#19](https://github.com/danielraffel/shipyard-macos-gui/pull/19))
- settings: clarify "Launch at login" footnote — say "restart" not "log in" ([#18](https://github.com/danielraffel/shipyard-macos-gui/pull/18))
- release: use POSIX awk for appcast item filtering ([#17](https://github.com/danielraffel/shipyard-macos-gui/pull/17))

<a id="v0110"></a>
## [0.1.10] - 2026-04-22

- daemon-client: hang-proof probe + auto-recovery instead of polling fallback ([#16](https://github.com/danielraffel/shipyard-macos-gui/pull/16))
- release: inline notes in appcast; tag URL for Version History ([#15](https://github.com/danielraffel/shipyard-macos-gui/pull/15))
- release: emit <sparkle:fullReleaseNotesLink> so Version History opens /releases ([#14](https://github.com/danielraffel/shipyard-macos-gui/pull/14))
- release: point appcast <link> at /releases for Sparkle's Version History button ([#13](https://github.com/danielraffel/shipyard-macos-gui/pull/13))
- release: use CURRENT_PROJECT_VERSION for sparkle:version in appcast ([#12](https://github.com/danielraffel/shipyard-macos-gui/pull/12))

<a id="v019"></a>
## [0.1.9] - 2026-04-22

- sparkle: built-in auto-update via appcast + per-release HTML notes ([#11](https://github.com/danielraffel/shipyard-macos-gui/pull/11))

<a id="v018"></a>
## [0.1.8] - 2026-04-22

- build: always regenerate xcodeproj + wipe DerivedData ([#10](https://github.com/danielraffel/shipyard-macos-gui/pull/10))
- settings: add "Launch Shipyard at login" toggle ([#9](https://github.com/danielraffel/shipyard-macos-gui/pull/9))

<a id="v017"></a>
## [0.1.7] - 2026-04-22

- tooltip: surface PR title on hover; daemon fast-path for ship-state list ([#8](https://github.com/danielraffel/shipyard-macos-gui/pull/8))

<a id="v016"></a>
## [0.1.6] - 2026-04-22

- fix: spinner stuck + empty-state collision + last-event counter ticks ([#7](https://github.com/danielraffel/shipyard-macos-gui/pull/7))

[0.1.18]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.18
[0.1.17]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.17
[0.1.16]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.16
[0.1.15]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.15
[0.1.14]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.14
[0.1.13]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.13
[0.1.12]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.12
[0.1.11]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.11
[0.1.10]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.10
[0.1.9]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.9
[0.1.8]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.8
[0.1.7]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.7
[0.1.6]: https://github.com/danielraffel/shipyard-macos-gui/releases/tag/v0.1.6
