#!/bin/bash
# Build, bundle and sign an .app for a SwiftPM product.
# Usage: scripts/build-app.sh <Product>    e.g. AirPodsMeetMute, MeetMuteSpike
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT="${1:?usage: scripts/build-app.sh <Product>}"
IDENTITY="${CODESIGN_IDENTITY:-Apple Development: you@example.com (XXXXXXXXXX)}"

swift build -c release --product "$PRODUCT"
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/$PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "Support/$PRODUCT-Info.plist" "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none \
    --entitlements "Support/$PRODUCT.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
