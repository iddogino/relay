#!/usr/bin/env python3
"""Checks what Scripts/archive-store.sh exported for App Store Connect.

  Scripts/check-store-export.py macos|ios <export folder> <version> <build>

The Mac's Relay.pkg or the iPhone and iPad's Relay.ipa is unpacked, and the
app inside must be the release it claims to be, signed as the App Store
takes it: Relay's bundle ID, Keychain group and iCloud container (or it
can't see the user's keys and synced hosts), iCloud and push in Production,
not debuggable, sandboxed on the Mac, with the privacy manifest and the
tmux bundle, and without Sparkle.
"""
import glob
import os
import plistlib
import subprocess
import sys
import tempfile

BUNDLE_ID = "com.iddogino.Relay"
TEAM = "HL9SP7TJ3J"
KEYCHAIN_GROUP = f"{TEAM}.{BUNDLE_ID}"
CLOUDKIT_CONTAINER = "iCloud.com.iddogino.Relay"

if len(sys.argv) != 5 or sys.argv[1] not in ("macos", "ios"):
    sys.exit(f"usage: {sys.argv[0]} macos|ios <export folder> <version> <build>")
platform, folder, version, build = sys.argv[1:]
mac = platform == "macos"
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def run(*command):
    return subprocess.run(command, capture_output=True, text=True)


with tempfile.TemporaryDirectory() as work:
    if mac:
        package = os.path.join(folder, "Relay.pkg")
        signature = run("pkgutil", "--check-signature", package)
        check(signature.returncode == 0 and f"({TEAM})" in signature.stdout,
              f"Relay.pkg isn't signed with the team's installer certificate: {signature.stdout.strip()}")
        expanded = os.path.join(work, "pkg")
        unpack = run("pkgutil", "--expand-full", package, expanded)
        if unpack.returncode != 0:
            sys.exit(f"error: can't unpack {package}: {unpack.stderr.strip()}")
        apps = glob.glob(os.path.join(expanded, "**", "Relay.app"), recursive=True)
        contents = os.path.join(apps[0], "Contents") if apps else ""
        resources = os.path.join(contents, "Resources")
        push_key = "com.apple.developer.aps-environment"
    else:
        # ditto keeps the symlinks and modes a signature covers.
        unpack = run("ditto", "-x", "-k", os.path.join(folder, "Relay.ipa"), os.path.join(work, "ipa"))
        if unpack.returncode != 0:
            sys.exit(f"error: can't unpack Relay.ipa: {unpack.stderr.strip()}")
        apps = glob.glob(os.path.join(work, "ipa", "Payload", "*.app"))
        contents = resources = apps[0] if apps else ""
        push_key = "aps-environment"
    if not apps:
        sys.exit("error: no app in the export")
    app = apps[0]

    with open(os.path.join(contents, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    signed = run("codesign", "-d", "--entitlements", "-", "--xml", app)
    entitlements = plistlib.loads(signed.stdout.encode()) if signed.returncode == 0 and signed.stdout else {}
    details = run("codesign", "-dvv", app).stderr
    verify = run("codesign", "--verify", "--deep", "--strict", app)

    check(info.get("CFBundleIdentifier") == BUNDLE_ID, f"bundle ID {info.get('CFBundleIdentifier')}")
    check(info.get("CFBundleShortVersionString") == version, f"version {info.get('CFBundleShortVersionString')}")
    check(info.get("CFBundleVersion") == build, f"build {info.get('CFBundleVersion')}")
    check(info.get("RelayKeychainAccessGroup") == KEYCHAIN_GROUP,
          f"Info.plist names Keychain group {info.get('RelayKeychainAccessGroup')}")
    check(info.get("RelayCloudKitContainer") == CLOUDKIT_CONTAINER,
          f"Info.plist names iCloud container {info.get('RelayCloudKitContainer')}")
    check(not info.get("RelayDevHookDirectory"), "names a dev hook folder")
    check("SUFeedURL" not in info, "has a Sparkle feed")

    check(verify.returncode == 0, f"signature doesn't verify: {verify.stderr.strip()}")
    check("Authority=Apple Distribution: " in details and f"TeamIdentifier={TEAM}" in details,
          "not signed with the team's Apple Distribution certificate")
    check(entitlements.get("keychain-access-groups") == [KEYCHAIN_GROUP],
          f"entitled to Keychain groups {entitlements.get('keychain-access-groups')}")
    check(entitlements.get("com.apple.developer.icloud-container-identifiers") == [CLOUDKIT_CONTAINER],
          f"entitled to iCloud containers {entitlements.get('com.apple.developer.icloud-container-identifiers')}")
    check(entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"],
          f"entitled to iCloud services {entitlements.get('com.apple.developer.icloud-services')}")
    check(entitlements.get("com.apple.developer.icloud-container-environment") == "Production",
          f"iCloud environment {entitlements.get('com.apple.developer.icloud-container-environment')}")
    check(entitlements.get(push_key) == "production", f"push environment {entitlements.get(push_key)}")
    check(not entitlements.get("get-task-allow") and not entitlements.get("com.apple.security.get-task-allow"),
          "debuggable (get-task-allow)")
    if mac:
        check(entitlements.get("com.apple.security.app-sandbox") is True, "not sandboxed")
        check(not any("temporary-exception" in key for key in entitlements),
              "has a sandbox temporary exception")
        check(not os.path.exists(os.path.join(contents, "Frameworks", "Sparkle.framework")), "embeds Sparkle")

    check(os.path.isfile(os.path.join(resources, "PrivacyInfo.xcprivacy")), "no privacy manifest")
    check(os.path.isfile(os.path.join(resources, "tmux", "manifest.json")), "no tmux bundle")
    check(os.path.isdir(os.path.join(resources, "terminfo")), "no terminfo")

if failures:
    for failure in failures:
        print(f"::error::Relay for {platform}: {failure}")
    sys.exit(1)
print(f"Relay {version} ({build}) for {platform}: signed for the App Store, Production iCloud and push, "
      f"privacy manifest, tmux bundle OK")
