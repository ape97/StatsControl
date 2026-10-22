#!/bin/zsh
# Checks Stats Control (scripts/check.sh: build, snapshots, self-test), installs it to /Applications and restarts it.
# Installs only if the check is green. Afterwards scripts/status.sh shows the result.
set -euo pipefail
cd "${0:A:h}/.."

./scripts/check.sh || { print "Not installed: check is red."; exit 1 }

TARGET="/Applications/StatsControl.app"
pkill -x StatsControl 2>/dev/null && sleep 0.5 || true
rm -rf "$TARGET"
ditto build/Build/Products/Release/StatsControl.app "$TARGET"
open -g "$TARGET"
sleep 2
print "\nStats Control installed: $TARGET"
./scripts/status.sh
