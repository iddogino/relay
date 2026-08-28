#!/usr/bin/env bash
# Builds Relay.app from the SwiftPM package.
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
#
# Environment:
#   RELAY_VERSION       CFBundleShortVersionString override (e.g. 0.1.0)
#   RELAY_BUILD_NUMBER  CFBundleVersion override (monotonic integer)
#   CODESIGN_IDENTITY   signing identity; default "-" (ad hoc). A real
#                       identity also enables the hardened runtime.
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

if [ -n "${RELAY_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELAY_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${RELAY_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELAY_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

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

# Embed Sparkle.framework (auto-updates). rsync preserves the framework's
# Versions symlink structure, which codesign requires.
SPARKLE_FW="$(find .build/artifacts -type d -name "Sparkle.framework" -not -path "*ios*" | head -1)"
if [ -z "$SPARKLE_FW" ]; then
  echo "error: Sparkle.framework not found under .build/artifacts (run swift build first)." >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
rsync -a --delete "$SPARKLE_FW" "$APP/Contents/Frameworks/"

IDENTITY="${CODESIGN_IDENTITY:--}"
sign() {
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$1" >/dev/null 2>&1
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
  fi
}

# Nested Sparkle executables must be signed inside-out before the framework,
# and the framework before the app (no --deep).
FW="$APP/Contents/Frameworks/Sparkle.framework"
for xpc in "$FW"/Versions/B/XPCServices/*.xpc; do
  [ -e "$xpc" ] && sign "$xpc"
done
[ -e "$FW/Versions/B/Autoupdate" ] && sign "$FW/Versions/B/Autoupdate"
[ -e "$FW/Versions/B/Updater.app" ] && sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
if [ "$IDENTITY" != "-" ]; then
  codesign --verify --strict --verbose=2 "$APP"
fi

echo "Built $APP ($CONFIG, signed: $IDENTITY)"
