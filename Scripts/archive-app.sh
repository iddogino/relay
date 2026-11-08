#!/usr/bin/env bash
# Builds build/Relay.app as a release ships it: the direct download
# (App/project.yml's Relay Direct), archived and exported Developer
# ID-signed. Notarizing and packaging are the release workflow's.
# Usage: Scripts/archive-app.sh
#
# Needs the Developer ID Application certificate in a keychain and the
# "Relay Developer ID" provisioning profile (the release workflow's
# MACOS_CERTIFICATE_P12 and MACOS_PROVISIONING_PROFILE).
#
# Environment:
#   RELAY_VERSION       CFBundleShortVersionString (e.g. 0.1.0, 0.1.0-rc.1)
#   RELAY_BUILD_NUMBER  CFBundleVersion (monotonic integer: Sparkle compares it)
#   RELAY_PROVISIONING_PROFILE
#                       the profile, when Xcode doesn't have it yet: it's
#                       installed where Xcode looks.
set -euo pipefail
cd "$(dirname "$0")/.."

XCFRAMEWORK="Vendor/ghostty/macos/GhosttyKit.xcframework"
if [ ! -d "$XCFRAMEWORK" ]; then
  echo "error: $XCFRAMEWORK not found. Run Scripts/build-libghostty.sh first." >&2
  exit 1
fi

if [ -n "${RELAY_PROVISIONING_PROFILE:-}" ]; then
  UUID="$(security cms -D -i "$RELAY_PROVISIONING_PROFILE" | plutil -extract UUID raw -)"
  PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  mkdir -p "$PROFILES"
  cp "$RELAY_PROVISIONING_PROFILE" "$PROFILES/$UUID.provisionprofile"
fi

VERSION_SETTINGS=()
[ -n "${RELAY_VERSION:-}" ] && VERSION_SETTINGS+=("MARKETING_VERSION=$RELAY_VERSION")
[ -n "${RELAY_BUILD_NUMBER:-}" ] && VERSION_SETTINGS+=("CURRENT_PROJECT_VERSION=$RELAY_BUILD_NUMBER")

xcodegen --spec App/project.yml --quiet
rm -rf build/Relay.xcarchive build/export build/Relay.app
xcodebuild archive -project App/Relay.xcodeproj -scheme "Relay Direct" -configuration Release \
  -destination 'generic/platform=macOS' ARCHS=arm64 -archivePath build/Relay.xcarchive \
  -derivedDataPath .build/xcode-release ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} -quiet
xcodebuild -exportArchive -archivePath build/Relay.xcarchive -exportPath build/export \
  -exportOptionsPlist App/Direct/ExportOptions.plist -quiet
mv build/export/Relay.app build/Relay.app
rm -rf build/export

Scripts/check-app.py "Relay Direct" Release build/Relay.app --distribution
echo "Built build/Relay.app ($(plutil -extract CFBundleShortVersionString raw build/Relay.app/Contents/Info.plist), build $(plutil -extract CFBundleVersion raw build/Relay.app/Contents/Info.plist))"
