#!/bin/bash
# Build, bundle and sign an .app for a SwiftPM product.
# Usage: scripts/build-app.sh <Product>    e.g. AirPodsMeetMute, MeetMuteSpike
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT="${1:?usage: scripts/build-app.sh <Product>}"
# Sign with a stable identity so macOS privacy grants (Microphone, Automation) survive
# rebuilds; ad-hoc signatures change on every build and re-prompt each time.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)}"
if [ -z "$IDENTITY" ]; then
    echo "No Apple Development signing identity found. Create one in Xcode (Settings › Accounts)," >&2
    echo "or set CODESIGN_IDENTITY to any code-signing identity from: security find-identity -v -p codesigning" >&2
    exit 1
fi
echo "Signing with: $IDENTITY"

swift build -c release --product "$PRODUCT"
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/$PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "Support/$PRODUCT-Info.plist" "$APP/Contents/Info.plist"
if [ -f "Support/AppIcon.icns" ] && grep -q CFBundleIconFile "Support/$PRODUCT-Info.plist"; then
    mkdir -p "$APP/Contents/Resources"
    cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ "$PRODUCT" = "AirPodsMeetMute" ]; then
    mkdir -p "$APP/Contents/Resources"
    cp Support/Sounds/*.wav "$APP/Contents/Resources/"
fi

codesign --force --options runtime --timestamp=none \
    --entitlements "Support/$PRODUCT.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
