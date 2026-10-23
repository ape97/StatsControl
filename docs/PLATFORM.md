# Platform status

The macOS/Xcode version Stats Control was last fully tested against (`scripts/check.sh` green, deployed).
`scripts/status.sh` compares the last `tested:` line with the running system.
Append new lines at the bottom and keep the format exactly.

tested: macOS=27.0.1 (26A434) Xcode=27.0 SDK=27.0 date=2026-10-16

## Dependencies on the system (what an update may break)
- **Overall GPU load** from IOKit `IOAccelerator` → `PerformanceStatistics` → "Device Utilization %" (`Stats/SystemStats.swift`).
  If Apple changes keys or classes, the GPU tile shows 0 – the self-test reports `gpu`.
- **GPU per process** from `AGXDeviceUserClient` → `IOUserClientCreator` ("pid N, name") plus `AppUsage[].accumulatedGPUTime`
  (`Stats/ProcessSampler.swift`). Private registry structure, the most likely to break.
- **CPU/memory per process**: `proc_pid_rusage` for own processes, `/bin/ps` (setuid) for foreign and root processes (`Stats/ProcessSampler.swift`).
- **Process → app** via `responsibility_get_pid_responsible_for_pid` (private) – if it breaks, helper processes appear instead of apps.
- **MenuBarExtra (.window)** and window notifications for detecting the menu closing (`App/StatsControlApp.swift`).
- **SMAppService** (login item) – `scripts/status.sh` checks it via `sfltool dumpbtm`.
- **Signature**: ad hoc by default; with your own certificate (`Config/Local.xcconfig`) the expiry date is shown by `scripts/status.sh`.
- **GitHub releases API** (`App/UpdateCheck.swift`), only while Check for Updates is on: `GET api.github.com/repos/ape97/StatsControl/releases/latest`,
  reads `tag_name` and `html_url`, ignores drafts and pre-releases. If GitHub changes this, only the update notice stops working.
