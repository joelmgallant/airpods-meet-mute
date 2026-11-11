#!/bin/bash
# Regenerates Support/AppIcon.icns from Support/AppIcon.svg.
# Needs Google Chrome (headless render) and ImageMagick (`magick`).
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$WORK/icon-1024.png" "file://$PWD/Support/AppIcon.svg" 2>"$WORK/chrome.log" \
    || { cat "$WORK/chrome.log"; exit 1; }

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    magick "$WORK/icon-1024.png" -resize "${size}x${size}" "$ICONSET/icon_${size}x${size}.png"
    magick "$WORK/icon-1024.png" -resize "$((size * 2))x$((size * 2))" "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
echo "Wrote Support/AppIcon.icns"
