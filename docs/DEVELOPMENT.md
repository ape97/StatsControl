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
| `./scripts/screenshots.sh` | Renders every page with demo data and composes the README images in `docs/images/`. |
| `./scripts/release.sh` | Builds the downloadable, ad-hoc signed and stripped `build/release/StatsControl-<version>.zip`. |
| `swift scripts/icon.swift <out.png>` | Draws the app icon (used when the icon changes). |

Typical loop: edit, `./scripts/check.sh`, look at `build/check/*.png`, then `./scripts/deploy.sh` to use it.

## Command-line modes

The app binary (`StatsControl.app/Contents/MacOS/StatsControl`) understands a few arguments used by the scripts:

- `--snapshot <base> [page]` renders a page off-screen to `<base>-light.png`, `<base>-dark.png` and `<base>-symbol.png`
  and exits. No window is shown. Pages are listed in `scripts/check.sh`.
- `--demo` (with `--snapshot`) replaces live measurements with fixed, invented data (`Stats/Demo.swift`), so screenshots
  never show your own processes.
- `--selftest <file.json>` measures, groups processes and quits a test process it started itself, then writes the
  result as JSON.

## Signing

Builds are ad-hoc signed (`Config/Signing.xcconfig`), so no developer account is needed. macOS ties the login item to
the code signature, so with ad-hoc signing you may have to switch **Open at Login** on again after a rebuild. To sign
with your own certificate, create the git-ignored `Config/Local.xcconfig`:

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

## Releasing

1. Raise `MARKETING_VERSION` in `project.yml`.
2. `./scripts/check.sh` must be green; refresh the README images with `./scripts/screenshots.sh` if the UI changed.
3. `./scripts/release.sh` builds the zip. It always signs ad hoc, even with `Local.xcconfig` present, because a personal
   certificate would put the developer's name into the signature, and it strips the binary so no build paths remain.
4. Commit, tag and publish, for example with the GitHub CLI:
   ```sh
   git tag v1.2.0 && git push --tags
   gh release create v1.2.0 build/release/StatsControl-1.2.0.zip --title "Stats Control 1.2.0" --notes "…"
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
- `MenuBarExtra` with `.window` style clips multi-line text unless it uses `.fixedSize(horizontal: false, vertical: true)`;
  snapshots don't show this, so check the real menu after layout changes.

## Contributing

Keep changes small and focused, run `./scripts/check.sh` before opening a pull request, and describe what you tested.
Settings get a short explanation below them (`SettingNote` in `UI/DesignKit.swift`).
