#!/bin/zsh
# Checks Stats Control fully invisibly: build (no errors/warnings), snapshots, self-test.
# Changes nothing on the system, opens no windows. Result: summary + exit code (0 = green).
set -uo pipefail
cd "${0:A:h}/.."
OUT=build/check
rm -rf $OUT; mkdir -p $OUT
failed=0
ok()   { print "✅ $1" }
fail() { print "❌ $1"; failed=1 }

xcodegen generate -q || { fail "xcodegen"; exit 1 }
xcodebuild -project StatsControl.xcodeproj -scheme StatsControl -configuration Release \
  -derivedDataPath build build > build/log.txt 2>&1
grep -q "BUILD SUCCEEDED" build/log.txt && ok "Build" || { fail "Build (build/log.txt)"; grep -E "error:" build/log.txt | head -20; exit 1 }
warn=$(grep -E "warning:" build/log.txt | grep -v appintents | sort -u)
[[ -z $warn ]] && ok "no warnings" || { fail "Warnings:"; print -- "$warn" | head -30 }

APP="$PWD/build/Build/Products/Release/StatsControl.app"
BIN="$APP/Contents/MacOS/StatsControl"
for v in "cpu:--tab cpu" "gpu:--tab gpu" "memory:--tab memory" "settings:--settings" "confirm:--tab cpu --armed" "compact:--settings --compact memory"; do
  name=${v%%:*}; args=(${=v#*:})
  "$BIN" --snapshot $OUT/$name $args >/dev/null 2>&1
  [[ -s $OUT/$name-light.png && -s $OUT/$name-dark.png ]] || fail "Snapshot $name"
done
ok "Snapshots in $OUT (look at them!)"

f=$OUT/selftest.json
open -n -g -a "$APP" --args --selftest $PWD/$f
for i in {1..60}; do [[ -f $f ]] && break; /bin/sleep 1; done
if [[ -f $f ]]; then
  python3 - "$f" <<'PY' && ok "Self-test" || fail "Self-test ($f)"
import json, sys
d = json.load(open(sys.argv[1]))
print(f"   ok={d.get('ok')} CPU={d.get('cpu')} GPU={d.get('gpu')} memory={d.get('memory')} "
      f"processes={d.get('processes')} apps={d.get('groupedApps')} killTest={d.get('killTest')} failures={d.get('failures')}")
sys.exit(0 if d.get("ok") is True and not d.get("failures") else 1)
PY
else
  fail "Self-test: no output"
fi
(( failed )) && print "\nRESULT: RED" || print "\nRESULT: GREEN"
exit $failed
