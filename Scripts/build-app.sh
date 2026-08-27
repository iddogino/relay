#!/usr/bin/env bash
# Builds Relay.app from the SwiftPM package.
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
XCFRAMEWORK="Vendor/ghostty/macos/GhosttyKit.xcframework"

if [ ! -d "$XCFRAMEWORK" ]; then
  echo "error: $XCFRAMEWORK not found. Run Scripts/build-libghostty.sh first." >&2
  exit 1
fi

swift build -c "$CONFIG" --product Relay

APP="build/Relay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/Relay" "$APP/Contents/MacOS/Relay"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ghostty runtime resources (themes for user configs, local terminfo).
# These are used locally only; nothing is ever installed on remote hosts.
SHARE="Vendor/ghostty/zig-out/share"
if [ -d "$SHARE/ghostty" ]; then
  rsync -a --delete "$SHARE/ghostty" "$APP/Contents/Resources/"
fi
if [ -d "$SHARE/terminfo" ]; then
  rsync -a --delete "$SHARE/terminfo" "$APP/Contents/Resources/"
fi

if [ -f "Resources/AppIcon.icns" ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP ($CONFIG)"
