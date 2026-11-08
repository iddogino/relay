#!/usr/bin/env python3
"""Checks a Relay.app built from App/project.yml: what makes it Relay.

  Scripts/check-app.py <scheme> <configuration> <path to .app>

The bundle ID, Keychain group and iCloud container must be the ones every
Relay build shares (the direct download's included), or the app launches
fine but can't see the user's SSH keys and passwords, or syncs somewhere
else. The entitlements are read from the file Xcode signs with, with its
build settings: an unsigned build (CI) has none of its own.
"""
import json
import os
import plistlib
import re
import subprocess
import sys

BUNDLE_ID = "com.iddogino.Relay"
KEYCHAIN_GROUP = "HL9SP7TJ3J.com.iddogino.Relay"
CLOUDKIT_CONTAINER = "iCloud.com.iddogino.Relay"
RESOURCES = ["Assets.car", "Relay.icns", "ghostty", "terminfo"]
GRAMMARS = "RelaySyntaxHighlighter_RelaySyntaxHighlighter.bundle"

scheme, configuration, app = sys.argv[1:4]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


output = subprocess.run(
    ["xcodebuild", "-showBuildSettings", "-json", "-project", "App/Relay.xcodeproj",
     "-scheme", scheme, "-configuration", configuration],
    check=True, capture_output=True, text=True).stdout
settings = next(t["buildSettings"] for t in json.loads(output) if t["target"] == scheme)


def expand(value):
    if isinstance(value, str):
        return re.sub(r"\$\((\w+)\)", lambda m: settings.get(m.group(1), ""), value)
    if isinstance(value, list):
        return [expand(v) for v in value]
    return value


with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
    info = plistlib.load(f)
with open(os.path.join("App", settings["CODE_SIGN_ENTITLEMENTS"]), "rb") as f:
    entitlements = {key: expand(value) for key, value in plistlib.load(f).items()}

check(info.get("CFBundleIdentifier") == BUNDLE_ID, f"bundle ID {info.get('CFBundleIdentifier')}")

group = info.get("RelayKeychainAccessGroup")
check(group == KEYCHAIN_GROUP, f"Info.plist names Keychain group {group}")
check(entitlements.get("keychain-access-groups") == [KEYCHAIN_GROUP],
      f"entitled to Keychain groups {entitlements.get('keychain-access-groups')}")

container = info.get("RelayCloudKitContainer")
check(container == CLOUDKIT_CONTAINER, f"Info.plist names iCloud container {container}")
check(entitlements.get("com.apple.developer.icloud-container-identifiers") == [CLOUDKIT_CONTAINER],
      f"entitled to iCloud containers {entitlements.get('com.apple.developer.icloud-container-identifiers')}")
check(entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"],
      f"entitled to iCloud services {entitlements.get('com.apple.developer.icloud-services')}")
check("com.apple.developer.aps-environment" in entitlements,
      "no push entitlement (CloudKit's sync engine needs it)")

resources = os.path.join(app, "Contents", "Resources")
for resource in RESOURCES:
    check(os.path.exists(os.path.join(resources, resource)), f"no {resource}")
check(any(path.endswith("/Grammars") and "swift.json" in files
          for path, _, files in os.walk(os.path.join(resources, GRAMMARS))),
      f"no grammars in {GRAMMARS}")

# The App Store app: sandboxed, and the App Store updates it.
check(entitlements.get("com.apple.security.app-sandbox") is True, "not sandboxed")
check("SUFeedURL" not in info, "has a Sparkle feed")
check(not os.path.exists(os.path.join(app, "Contents", "Frameworks", "Sparkle.framework")), "embeds Sparkle")

if failures:
    for failure in failures:
        print(f"::error::{scheme} ({configuration}): {failure}")
    sys.exit(1)
print(f"{scheme} ({configuration}) {info.get('CFBundleShortVersionString')}: bundle ID, "
      "Keychain group, iCloud container, resources OK; sandboxed, no Sparkle")
