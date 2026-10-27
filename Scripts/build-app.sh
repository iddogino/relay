#!/usr/bin/env bash
# Builds Relay.app from the SwiftPM package.
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
#
# Environment:
#   RELAY_VERSION       CFBundleShortVersionString override (e.g. 0.1.0)
#   RELAY_BUILD_NUMBER  CFBundleVersion override (monotonic integer)
#   CODESIGN_IDENTITY   signing identity; default "-" (ad hoc). A real
#                       identity also enables the hardened runtime.
#   RELAY_VARIANT       "dev" builds "Relay Dev.app": separate bundle ID,
#                       data folder and defaults, no auto-updates — safe to
#                       run next to an installed Relay.
#   RELAY_PROVISIONING_PROFILE
#                       a provisioning profile covering the bundle ID (with
#                       CODESIGN_IDENTITY its certificate). Embedded, and the
#                       app gets a Keychain access group: SSH keys can then
#                       sync through iCloud Keychain. Without it, Relay keys
#                       are Secure Enclave only.
#   RELAY_SANDBOX       "1" turns on the App Sandbox (what the Mac App Store
#                       requires): network client access, files the user
#                       picks, and bookmarks to them — nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
XCFRAMEWORK="Vendor/ghostty/macos/GhosttyKit.xcframework"

if [ ! -d "$XCFRAMEWORK" ]; then
  echo "error: $XCFRAMEWORK not found. Run Scripts/build-libghostty.sh first." >&2
  exit 1
fi

swift build -c "$CONFIG" --product Relay

VARIANT="${RELAY_VARIANT:-}"
if [ "$VARIANT" = "dev" ]; then
  APP="build/Relay Dev.app"
else
  APP="build/Relay.app"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/Relay" "$APP/Contents/MacOS/Relay"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ "$VARIANT" = "dev" ]; then
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.iddogino.Relay.dev" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Relay Dev" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Relay Dev" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :RelayDataDirectory string Relay Dev" "$PLIST"
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PLIST"
fi
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

# App icon. Resources/Relay.icon (Icon Composer) compiles into the layered
# macOS 26+ icon — light/dark/tinted appearances — plus the flattened .icns
# actool derives for older systems. actool understands .icon only from
# Xcode 26: when the selected toolchain is older, try every installed
# Xcode, and failing that ship the pre-rendered Resources/AppIcon.icns
# (same artwork, flattened light appearance only).
compile_icon() {
  local out="$1" dev="${2:-}"
  local -a run=(xcrun actool)
  [ -n "$dev" ] && run=(env "DEVELOPER_DIR=$dev" xcrun actool)
  "${run[@]}" \
    --output-format human-readable-text \
    --output-partial-info-plist "$out/icon-partial.plist" \
    --app-icon Relay --development-region en --target-device mac \
    --minimum-deployment-target 15.0 --platform macosx \
    --compile "$out" Resources/Relay.icon >/dev/null 2>&1 &&
    [ -f "$out/Assets.car" ] && [ -f "$out/Relay.icns" ]
}

ICON_OUT="build/icon-compile"
rm -rf "$ICON_OUT" && mkdir -p "$ICON_OUT"
ICON_COMPILED=0
if [ -d "Resources/Relay.icon" ]; then
  if compile_icon "$ICON_OUT"; then
    ICON_COMPILED=1
  else
    for XCODE in $(ls -d /Applications/Xcode*.app 2>/dev/null | sort -rV); do
      if compile_icon "$ICON_OUT" "$XCODE"; then ICON_COMPILED=1; break; fi
    done
  fi
fi
if [ "$ICON_COMPILED" = 1 ]; then
  cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
  cp "$ICON_OUT/Relay.icns" "$APP/Contents/Resources/Relay.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile Relay" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Relay" "$APP/Contents/Info.plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName Relay" "$APP/Contents/Info.plist"
  echo "App icon: Relay.icon compiled (light/dark/tinted + icns fallback)"
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "App icon: pre-rendered AppIcon.icns (no .icon-capable actool found)"
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

# Keychain entitlement from a provisioning profile: the access group is
# <team>.<bundle ID>, shared by every Relay build of that bundle ID.
ENTITLEMENTS=""
PROFILE="${RELAY_PROVISIONING_PROFILE:-}"
if [ -n "$PROFILE" ]; then
  if [ "$IDENTITY" = "-" ]; then
    echo "error: RELAY_PROVISIONING_PROFILE needs CODESIGN_IDENTITY (the profile's certificate)." >&2
    exit 1
  fi
  PROFILE_PLIST="build/profile.plist"
  security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
  TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  GROUP="$TEAM.$BUNDLE_ID"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  /usr/libexec/PlistBuddy -c "Add :RelayKeychainAccessGroup string $GROUP" "$APP/Contents/Info.plist"
  ENTITLEMENTS="build/Relay.entitlements"
  cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>keychain-access-groups</key><array><string>$GROUP</string></array>
</dict>
</plist>
PLIST
  if /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.get-task-allow' "$PROFILE_PLIST" 2>/dev/null | grep -q true; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$ENTITLEMENTS"
  fi
  rm -f "$PROFILE_PLIST"
fi

# App Sandbox: added to the profile's entitlements, or on its own (ad hoc
# builds can be sandboxed too).
if [ "${RELAY_SANDBOX:-}" = "1" ]; then
  if [ -z "$ENTITLEMENTS" ]; then
    ENTITLEMENTS="build/Relay.entitlements"
    cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
  fi
  for key in com.apple.security.app-sandbox com.apple.security.network.client \
             com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope; do
    /usr/libexec/PlistBuddy -c "Add :$key bool true" "$ENTITLEMENTS"
  done
  # Dev builds: the automation hooks' folder (the container is off-limits
  # to other tools), the one exception to the sandbox.
  if [ "$VARIANT" = "dev" ]; then
    HOOK_DIR="/private/tmp/relay-dev-hook/"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write array" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write:0 string $HOOK_DIR" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :RelayDevHookDirectory string $HOOK_DIR" "$APP/Contents/Info.plist"
  fi
fi

# Nested Sparkle executables must be signed inside-out before the framework,
# and the framework before the app (no --deep).
FW="$APP/Contents/Frameworks/Sparkle.framework"
for xpc in "$FW"/Versions/B/XPCServices/*.xpc; do
  [ -e "$xpc" ] && sign "$xpc"
done
[ -e "$FW/Versions/B/Autoupdate" ] && sign "$FW/Versions/B/Autoupdate"
[ -e "$FW/Versions/B/Updater.app" ] && sign "$FW/Versions/B/Updater.app"
sign "$FW"
if [ -n "$ENTITLEMENTS" ] && [ "$IDENTITY" = "-" ]; then
  codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP"
elif [ -n "$ENTITLEMENTS" ]; then
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  sign "$APP"
fi
if [ "$IDENTITY" != "-" ]; then
  codesign --verify --strict --verbose=2 "$APP"
fi

echo "Built $APP ($CONFIG, signed: $IDENTITY)"
