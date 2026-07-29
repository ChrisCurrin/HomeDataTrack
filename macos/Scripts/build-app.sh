#!/bin/bash
# Assembles DataTrack.app from the SwiftPM build product.
#
# Xcode is not required — only the Command Line Tools. SwiftPM cannot emit an
# .app bundle, so the bundle is laid out by hand and ad-hoc signed.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${1:-$ROOT/build/DataTrack.app}"

echo "==> Building release binaries"
swift build -c release

BIN="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DataTrackMenuBar" "$APP/Contents/MacOS/DataTrackMenuBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. This is enough for Location Services to prompt, but the
# signing identity changes on every rebuild, so macOS may re-ask for permission
# after an update. A real Developer ID certificate makes the grant stick.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo ""
echo "Built $APP"
echo ""
echo "Run it:      open '$APP'"
echo "Install it:  cp -R '$APP' /Applications/"
echo ""
echo "The menu bar item shows today's usage, or percent-of-budget once you set one."
