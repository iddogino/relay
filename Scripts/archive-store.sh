#!/usr/bin/env bash
# Builds the App Store app (App/project.yml's Relay) as App Store Connect
# takes it: archived, then exported signed for distribution — the Mac's
# build/store/macos/Relay.pkg, or the iPhone and iPad's
# build/store/ios/Relay.ipa — and, with --upload, sent there.
#
#   Scripts/archive-store.sh macos|ios [--upload]
#
# Needs the team's Apple Distribution certificate (and, for the Mac, its
# Mac Installer Distribution one) in a keychain, Xcode signed in to the
# team (it makes the App Store provisioning profiles), GhosttyKit with the
# platform's slices (Scripts/build-libghostty.sh; --universal for iOS), and
# build/tmux (Scripts/build-tmux.sh): a release always bundles it.
#
# Environment:
#   RELAY_VERSION       CFBundleShortVersionString: three numbers (0.2.0).
#                       The App Store takes no prerelease suffix.
#   RELAY_BUILD_NUMBER  CFBundleVersion: an integer above every build
#                       already uploaded for this version and platform. By
#                       Scripts/release-version.py's numbering, the nth
#                       upload of 0.2.0 is 20000 + n.
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:-}"
UPLOAD=0
[ "${2:-}" = "--upload" ] && UPLOAD=1
case "$PLATFORM" in
  # The Mac's slice is macos-arm64, or macos-arm64_x86_64 built --universal.
  macos) DESTINATION="generic/platform=macOS"; SLICE="macos-arm64*" ;;
  ios) DESTINATION="generic/platform=iOS"; SLICE="ios-arm64" ;;
  *) echo "usage: $0 macos|ios [--upload]" >&2; exit 2 ;;
esac
if [ $# -gt 2 ] || { [ $# -eq 2 ] && [ "$UPLOAD" != 1 ]; }; then
  echo "usage: $0 macos|ios [--upload]" >&2; exit 2
fi

if ! [[ "${RELAY_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: RELAY_VERSION must be three numbers (e.g. 0.2.0), not '${RELAY_VERSION:-}'." >&2
  exit 1
fi
if ! [[ "${RELAY_BUILD_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: RELAY_BUILD_NUMBER must be a whole number, not '${RELAY_BUILD_NUMBER:-}'." >&2
  exit 1
fi

XCFRAMEWORK="Vendor/ghostty/macos/GhosttyKit.xcframework"
# Unquoted: the Mac's is a pattern.
if ! compgen -G "$XCFRAMEWORK/$SLICE" > /dev/null; then
  echo "error: $XCFRAMEWORK has no $PLATFORM slice. Run Scripts/build-libghostty.sh$([ "$PLATFORM" = ios ] && echo " --universal") first." >&2
  exit 1
fi
if [ ! -f build/tmux/manifest.json ]; then
  echo "error: build/tmux not found. Run Scripts/build-tmux.sh first: a release always bundles it." >&2
  exit 1
fi

OUT="build/store/$PLATFORM"
ARCHIVE="$OUT/Relay.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

xcodegen --spec App/project.yml --quiet
xcodebuild archive -project App/Relay.xcodeproj -scheme Relay -configuration Release \
  -destination "$DESTINATION" ARCHS=arm64 -archivePath "$ARCHIVE" \
  -derivedDataPath ".build/xcode-store-$PLATFORM" -allowProvisioningUpdates \
  "MARKETING_VERSION=$RELAY_VERSION" "CURRENT_PROJECT_VERSION=$RELAY_BUILD_NUMBER" -quiet

# The archived app, before anything leaves this Mac.
if [ "$PLATFORM" = macos ]; then
  Scripts/check-app.py Relay Release "$ARCHIVE/Products/Applications/Relay.app" --tmux
fi

# Exported signed for distribution (always: what's checked below is what
# App Store Connect would get), then uploaded if asked.
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
  -exportOptionsPlist App/Store/ExportOptions.plist -allowProvisioningUpdates -quiet
Scripts/check-store-export.py "$PLATFORM" "$OUT" "$RELAY_VERSION" "$RELAY_BUILD_NUMBER"

if [ "$UPLOAD" = 1 ]; then
  OPTIONS="$OUT/UploadOptions.plist"
  cp App/Store/ExportOptions.plist "$OPTIONS"
  plutil -replace destination -string upload "$OPTIONS"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/upload" \
    -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates
  echo "Uploaded Relay $RELAY_VERSION ($RELAY_BUILD_NUMBER) for $PLATFORM to App Store Connect."
fi
