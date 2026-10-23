# Development

Everything you need to change, build, install and release Stats Control yourself.

## Prerequisites

- macOS 26 or later on Apple silicon, Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The Xcode project is generated from `project.yml` and not checked in. Run `xcodegen generate` and open
`StatsControl.xcodeproj` if you want to work in Xcode; the scripts below generate it themselves.

## Project layout

```
project.yml                 XcodeGen project (version in MARKETING_VERSION)
Config/Signing.xcconfig     ad-hoc signing by default, optional Config/Local.xcconfig
StatsControl/
  App/                      app entry, AppModel (state, timers, settings), SelfTest
  Stats/                    SystemStats, ProcessSampler, ProcessActions, Demo (screenshot data)
  UI/                       MenuBarLabel, MenuView, SettingsPage, DesignKit (shared styles), SystemLinks
  Resources/                Info.plist, asset catalog (app icon)
scripts/                    check, deploy, status, screenshots, release, icon
docs/                       PLATFORM.md (tested macOS/Xcode), images/ (README screenshots)
```

## Scripts

| Script | What it does |
|---|---|
| `./scripts/check.sh` | The gate. Warning-free Release build, invisible snapshots of every page into `build/check/`, self-test. Ends with `RESULT: GREEN` or `RED`. Changes nothing on the system. |
| `./scripts/deploy.sh` | Runs the check; only if green, installs to `/Applications` and restarts the app. |
| `./scripts/status.sh` | Shows the installed version, running state, login item and signature, and compares the system with the last tested one in `docs/PLATFORM.md`. |
| `./scripts/screenshots.sh` | Renders every page with demo data and composes the README images in `docs/images/`: every page in dark mode, the main page in light mode too, and `compact.gif` (needs `ffmpeg`, `brew install ffmpeg`). Each animation in `scripts/scenes/*.json` (cursor, clicks and captions over the rendered pages, `compose.swift --scene`) becomes `docs/images/<name>.gif`; the app icon is copied to `docs/images/icon.png`. |
| `./scripts/release.sh` | Builds the downloadable, ad-hoc signed and stripped `build/release/StatsControl-<version>.zip`. |
| `swift scripts/icon.swift <out.png>` | Draws the app icon (used when the icon changes). |

Typical loop: edit, `./scripts/check.sh`, look at `build/check/*.png`, then `./scripts/deploy.sh` to use it.

## Command-line modes

The app binary (`StatsControl.app/Contents/MacOS/StatsControl`) understands a few arguments used by the scripts:

- `--snapshot <base> [page]` renders a page off-screen to `<base>-light.png`, `<base>-dark.png` and `<base>-symbol.png`
  and exits. No window is shown. Pages are listed in `scripts/check.sh`.
- `--demo` (with `--snapshot`) replaces live measurements with fixed, invented data (`Stats/Demo.swift`), so screenshots
  never show your own processes.
- `--timeline <dir>` (with `--snapshot`) writes the frames of the compact mode animation: one menu bar symbol per frame
  and `frames.json` with durations, captions and pointer positions. The values are scripted, while threshold, hysteresis,
  column choice and easing are the app's own. `scripts/compose.swift --frames` places each frame in a menu bar and
  `scripts/screenshots.sh` joins them into `docs/images/compact.gif`.
- `--update <version>` (with `--snapshot`) pretends a newer release exists, so the update notice is rendered.
- `--selftest <file.json>` measures, groups processes and quits a test process it started itself, then writes the
  result as JSON.
- `--check-update <file.json>` asks GitHub once for the latest release, exactly like the update check, and writes the
  result as JSON (current and latest version, whether the notice would show). Manual test only, never part of `check.sh`.

## Signing

Builds are ad-hoc signed (`Config/Signing.xcconfig`), so no developer account is needed. macOS ties the login item to
the code signature, so with ad-hoc signing you may have to switch **Open at Login** on again after a rebuild. To sign
with your own certificate, create the git-ignored `Config/Local.xcconfig`:

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

## Releasing

Every published release reaches users who switched on **Check for Updates** within a day, so releases are deliberate:

- Only GitHub releases count: commits, pushes and tags never trigger the notice, and neither do drafts or pre-releases
  (`releases/latest` skips them). Use `gh release create … --prerelease` for a build someone should try first.
- Bundle small changes; documentation, images and scripts alone don't need a release.
- Tag every release `v<version>` with a plain numeric version (`1.10.0` is newer than `1.9.3`).
- Never publish a release just to test the notice: build a zip with a lower version locally and run it with `--check-update`.

1. Raise `MARKETING_VERSION` in `project.yml`.
2. `./scripts/check.sh` must be green; refresh the README images with `./scripts/screenshots.sh` if the UI changed.
3. `./scripts/release.sh` builds the zip. It always signs ad hoc, even with `Local.xcconfig` present, because a personal
   certificate would put the developer's name into the signature, and it strips the binary so no build paths remain.
   The signature's designated requirement is the bundle identifier instead of the ad-hoc default (one exact build), so
   permissions granted in System Settings stay valid after an update.
4. Commit, tag and publish, for example with the GitHub CLI:
   ```sh
   git tag -a v1.3.0 -m "Stats Control 1.3.0" && git push origin v1.3.0
   gh release create v1.3.0 build/release/StatsControl-1.3.0.zip --title "Stats Control 1.3.0" --notes "…"
   ```

## After a macOS or Xcode update

Run `./scripts/status.sh`. If the system differs from the last `tested:` line in `docs/PLATFORM.md`, run
`./scripts/check.sh`, fix what broke and append a new `tested:` line. `docs/PLATFORM.md` also lists the system
interfaces most likely to change.

## How it works

- `Stats/SystemStats.swift` measures totals: CPU via Mach host statistics, RAM like Activity Monitor, GPU utilization
  via IOKit (`IOAccelerator` performance statistics).
- `Stats/ProcessSampler.swift` measures per process: `proc_pid_rusage` for own processes, `/bin/ps` for others, GPU time
  from the graphics driver's registry entries (`AGXDeviceUserClient`). Processes are mapped to their app with
  `responsibility_get_pid_responsible_for_pid`.
- Totals are measured every 2 s. The process list refreshes every 2 s while the menu is open and every 30 s while closed;
  one measurement takes about 13 ms.
- While the menu is open the layout never changes structurally (hidden quit buttons, rows by position, list height only
  grows), because every structural change makes macOS reset the mouse pointer. Text animations that change size are
  avoided too, since CoreGraphics caches every intermediate glyph bitmap.
- **Update check** (`App/UpdateCheck.swift`, off by default): at most once a day (on launch, when the menu opens, after
  waking; no timer) a single `GET https://api.github.com/repos/ape97/StatsControl/releases/latest`. Only `tag_name` and
  `html_url` are read; a newer version shows a notice in the menu whose **Download** opens the release page. Nothing is
  downloaded or installed by the app.
- `MenuBarExtra` with `.window` style clips multi-line text unless it uses `.fixedSize(horizontal: false, vertical: true)`;
  snapshots don't show this, so check the real menu after layout changes.

## Contributing

Keep changes small and focused, run `./scripts/check.sh` before opening a pull request, and describe what you tested.
Settings get a short explanation below them (`SettingNote` in `UI/DesignKit.swift`).
