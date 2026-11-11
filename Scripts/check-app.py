#!/usr/bin/env python3
"""Checks a Relay.app built from App/project.yml: what makes it Relay.

  Scripts/check-app.py <scheme> <configuration> <path to .app> [--distribution] [--tmux]

The bundle ID, Keychain group and iCloud container must be the ones every
Relay build shares, or the app launches fine but can't see the user's SSH
keys and passwords, or syncs somewhere else. The direct download must also
keep its update feed and key, or installed copies stop updating.

The entitlements are read from the file Xcode signs with, with its build
settings: an unsigned build (CI) has none of its own. With --distribution,
the app must be signed as a release is (Developer ID, notarizable), and its
signature's entitlements are checked instead.

With --tmux (implied by --distribution), the app must bundle the tmux builds
it installs on hosts that have none (Scripts/build-tmux.sh), whole: a build
without them still runs, and only tells a user so when they need one.
"""
import gzip
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

BUNDLE_ID = "com.iddogino.Relay"
TEAM = "HL9SP7TJ3J"
KEYCHAIN_GROUP = f"{TEAM}.{BUNDLE_ID}"
CLOUDKIT_CONTAINER = "iCloud.com.iddogino.Relay"
SPARKLE_FEED = "https://raw.githubusercontent.com/iddogino/relay/main/appcast.xml"
SPARKLE_KEY = "83fVWPb/G/hc2hYzYyoKW7eB/abuYzTSIJJYvMwIdvA="
RESOURCES = ["Assets.car", "Relay.icns", "ghostty", "terminfo"]
GRAMMARS = "RelaySyntaxHighlighter_RelaySyntaxHighlighter.bundle"
STORE, DIRECT = "Relay", "Relay Direct"

FLAGS = ("--distribution", "--tmux")
args = [a for a in sys.argv[1:] if a not in FLAGS]
distribution = "--distribution" in sys.argv
require_tmux = distribution or "--tmux" in sys.argv
if len(args) != 3 or args[0] not in (STORE, DIRECT) or (distribution and args[0] != DIRECT):
    sys.exit(f"usage: {sys.argv[0]} '{STORE}'|'{DIRECT}' <configuration> <app> "
             f"[--distribution: {DIRECT} only] [--tmux]")
scheme, configuration, app = args
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def run(*command):
    return subprocess.run(command, capture_output=True, text=True)


with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
    info = plistlib.load(f)

if distribution:
    signed = run("codesign", "-d", "--entitlements", "-", "--xml", app)
    entitlements = plistlib.loads(signed.stdout.encode()) if signed.returncode == 0 and signed.stdout else {}
else:
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

# The tmux bundle: every file its manifest lists, the size and content the
# manifest says. Checked whenever it's there; required for a release.
TMUX_FILES = ["tmux-linux-x86_64.gz", "tmux-linux-aarch64.gz", "tmux-darwin-universal.gz", "terminfo.tar.gz"]
tmux = os.path.join(resources, "tmux")
tmux_summary = "no tmux bundle"
if os.path.exists(os.path.join(tmux, "manifest.json")):
    with open(os.path.join(tmux, "manifest.json")) as f:
        manifest = json.load(f)
    files = manifest.get("files", {})
    check(bool(manifest.get("version")), "tmux bundle: the manifest has no version")
    for name in TMUX_FILES:
        entry, path = files.get(name), os.path.join(tmux, name)
        if entry is None or not os.path.isfile(path):
            check(False, f"tmux bundle: no {name}")
            continue
        with open(path, "rb") as f:
            data = f.read()
        check(len(data) == entry.get("size"), f"tmux bundle: {name} is {len(data)} bytes, the manifest says {entry.get('size')}")
        if "sha256" in entry:
            check(hashlib.sha256(data).hexdigest() == entry["sha256"], f"tmux bundle: {name} doesn't match its checksum")
        else:
            try:
                binary = gzip.decompress(data)
            except OSError:
                binary = b""
            check(hashlib.sha256(binary).hexdigest() == entry.get("uncompressedSha256"),
                  f"tmux bundle: {name} doesn't unpack to the binary the manifest names")
    tmux_summary = f"tmux {manifest.get('version')} bundle"
elif require_tmux:
    check(False, "no tmux bundle (Scripts/build-tmux.sh makes build/tmux, which the build picks up)")

sparkle = os.path.join(app, "Contents", "Frameworks", "Sparkle.framework")
sandboxed = entitlements.get("com.apple.security.app-sandbox") is True
if scheme == STORE:
    # The App Store app: sandboxed, and the App Store updates it.
    check(sandboxed, "not sandboxed")
    check("SUFeedURL" not in info and "SUPublicEDKey" not in info, "has a Sparkle feed or key")
    check(not os.path.exists(sparkle), "embeds Sparkle")
    summary = "sandboxed, no Sparkle"
else:
    # The direct download: Sparkle updates it, from the feed and with the
    # key every installed copy already has.
    check(not sandboxed, "sandboxed")
    check(info.get("SUFeedURL") == SPARKLE_FEED, f"Sparkle feed {info.get('SUFeedURL')}")
    check(info.get("SUPublicEDKey") == SPARKLE_KEY, f"Sparkle key {info.get('SUPublicEDKey')}")
    check(os.path.exists(os.path.join(sparkle, "Versions", "B", "Sparkle")), "doesn't embed Sparkle")
    summary = "Sparkle feed and key"

if distribution:
    # As notarization requires, and as Sparkle checks an update against
    # the installed copy: Developer ID and a secure timestamp on every
    # piece of code, the hardened runtime on every executable, the release
    # environments.
    verify = run("codesign", "--verify", "--deep", "--strict", app)
    check(verify.returncode == 0, f"signature doesn't verify: {verify.stderr.strip()}")
    libraries = [os.path.join(app, "Contents", "Frameworks", name)
                 for name in sorted(os.listdir(os.path.join(app, "Contents", "Frameworks")))]
    executables = [app] + [os.path.join(sparkle, "Versions", "B", name) for name in ("Autoupdate", "Updater.app")]
    xpc = os.path.join(sparkle, "Versions", "B", "XPCServices")
    if os.path.isdir(xpc):
        executables += [os.path.join(xpc, name) for name in sorted(os.listdir(xpc))]
    for code in executables + libraries:
        name = os.path.relpath(code, os.path.dirname(app))
        details = run("codesign", "-dvv", code).stderr
        check(f"Authority=Developer ID Application: " in details and f"TeamIdentifier={TEAM}" in details,
              f"{name}: not signed with the Developer ID certificate")
        check("Timestamp=" in details, f"{name}: no secure timestamp")
        if code in executables:
            check(re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", details) is not None,
                  f"{name}: no hardened runtime")
    check(entitlements.get("com.apple.developer.icloud-container-environment") == "Production",
          f"iCloud environment {entitlements.get('com.apple.developer.icloud-container-environment')}")
    check(entitlements.get("com.apple.developer.aps-environment") == "production",
          f"push environment {entitlements.get('com.apple.developer.aps-environment')}")
    check(not entitlements.get("com.apple.security.get-task-allow"), "debuggable (get-task-allow)")
    profile = run("security", "cms", "-D", "-i", os.path.join(app, "Contents", "embedded.provisionprofile"))
    profile_app_id = (plistlib.loads(profile.stdout.encode()).get("Entitlements", {})
                      .get("com.apple.application-identifier") if profile.returncode == 0 else None)
    check(profile_app_id == KEYCHAIN_GROUP, f"embedded profile is for {profile_app_id}")
    summary += "; Developer ID, hardened runtime, timestamped, Production"

if failures:
    for failure in failures:
        print(f"::error::{scheme} ({configuration}): {failure}")
    sys.exit(1)
print(f"{scheme} ({configuration}) {info.get('CFBundleShortVersionString')}: bundle ID, "
      f"Keychain group, iCloud container, resources OK; {tmux_summary}; {summary}")
