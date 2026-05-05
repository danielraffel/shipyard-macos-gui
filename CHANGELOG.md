# Changelog

All notable changes to shipyard-macos-gui are documented here. Each entry links
to its [GitHub Release](https://github.com/danielraffel/shipyard-macos-gui/releases).

## Unreleased

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
