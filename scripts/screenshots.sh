#!/bin/zsh
# Renders every menu page with invented demo data and composes the README images into docs/images/.
# Invisible: no windows; nothing is read from or written to your settings.
set -euo pipefail
cd "${0:A:h}/.."
BIN=StatsControl
COLORS=(5CDB85 084559)   # the icon's gradient colours, see scripts/icon.swift
# page:snapshot arguments (the first page also provides the menu bar icon)
PAGES=("main:--tab cpu" "gpu:--tab gpu" "memory:--tab memory" "confirm:--tab cpu --armed" "settings:--settings --compact cpu")
# Extra states only the animations use (rendered, not composed): each tab a few samples later.
EXTRA=()
for tab in cpu gpu memory; do for step in 1 2 3; do EXTRA+=("$tab-$step:--tab $tab --step $step"); done; done

mkdir -p build
xcodegen generate -q
xcodebuild -project $BIN.xcodeproj -scheme $BIN -configuration Release -derivedDataPath build build > build/screenshots-build.log 2>&1 \
  || { tail -20 build/screenshots-build.log; exit 1 }
RAW=build/screenshots/raw
rm -rf $RAW; mkdir -p $RAW docs/images
for page in $PAGES $EXTRA; do
  build/Build/Products/Release/$BIN.app/Contents/MacOS/$BIN --snapshot $RAW/${page%%:*} ${=page#*:} --demo >/dev/null 2>&1
done
swift scripts/compose.swift $RAW docs/images $COLORS ${PAGES%%:*}
cp StatsControl/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png docs/images/icon.png   # README header

# The compact mode animation: the app writes the menu bar symbol frame by frame, compose.swift puts each into the menu bar,
# ffmpeg joins them into a looping GIF at double resolution with one shared palette (skipped without ffmpeg: brew install ffmpeg).
FRAMES=build/screenshots/frames
rm -rf $FRAMES; mkdir -p $FRAMES/out
build/Build/Products/Release/$BIN.app/Contents/MacOS/$BIN --snapshot $FRAMES/menu --demo --timeline $FRAMES >/dev/null 2>&1
swift scripts/compose.swift --frames $FRAMES $FRAMES/out $COLORS
if command -v ffmpeg >/dev/null; then
  ffmpeg -v error -y -f concat -i $FRAMES/out/frames.txt \
    -vf "split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
    -fps_mode vfr -loop 0 docs/images/compact.gif
  print docs/images/compact.gif
else
  print "ffmpeg not found: docs/images/compact.gif not updated"
fi

# Animations: every scripts/scenes/<name>.json plays over the pages above (see compose.swift --scene); ffmpeg joins the
# frames into docs/images/<name>.gif with one shared palette, writing only the changed area of each frame
# (15 fps and at most 1200 px wide keep a 20-second walkthrough near 2–3 MB).
if command -v ffmpeg >/dev/null; then
  for scene in scripts/scenes/*.json(N); do
    out=build/screenshots/scene-${scene:t:r}
    rm -rf $out; mkdir -p $out
    swift scripts/compose.swift --scene $scene $RAW $out $COLORS
    ffmpeg -v error -y -f concat -i $out/frames.txt \
      -vf "fps=15,scale='min(iw,1200)':-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
      -loop 0 docs/images/${scene:t:r}.gif
    print docs/images/${scene:t:r}.gif
  done
else
  print "ffmpeg not found: animations not updated (brew install ffmpeg)"
fi
