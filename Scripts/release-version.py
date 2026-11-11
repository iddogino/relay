#!/usr/bin/env python3
"""A release tag's version and build number.

  Scripts/release-version.py v0.2.0-rc.3
  version=0.2.0-rc.3
  build=20003
  prerelease=true
  channel=rc

Tags are v<major>.<minor>.<patch> (stable) or
v<major>.<minor>.<patch>-<channel>.<sequence> (prerelease).

The build number (CFBundleVersion, what Sparkle compares) follows from the
version, so a later *version* is always a later build, whenever it's built:

  major * 1,000,000 + minor * 10,000 + patch * 100 + sequence

with a stable release taking sequence 99, above its prereleases. A patch
release of an older line (0.1.14 after 0.2.0-rc.1) therefore sorts below the
newer line and is never offered to it as an update, and building a tag again
gives the same number. Hence the limits: minor and patch under 100, a
prerelease sequence from 1 to 98.

(Releases up to 0.2.0-rc.1 were numbered by workflow run, 1 to 26: every
number made here is above those.)
"""
import re
import sys

STABLE_SEQUENCE = 99


def parse(tag: str) -> dict[str, str]:
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z]+)\.(\d+))?", tag)
    if not match:
        raise ValueError(
            f"tag '{tag}' is not v<semver> or v<semver>-<channel>.<sequence> (e.g. v0.1.0, v0.1.0-rc.1)")
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    channel = match.group(4)
    if minor > 99 or patch > 99:
        raise ValueError(f"tag '{tag}': minor and patch must be under 100 (the build number has two digits for each)")
    if channel is None:
        sequence = STABLE_SEQUENCE
    else:
        sequence = int(match.group(5))
        if not 1 <= sequence < STABLE_SEQUENCE:
            raise ValueError(f"tag '{tag}': the prerelease sequence must be from 1 to {STABLE_SEQUENCE - 1}")
    build = major * 1_000_000 + minor * 10_000 + patch * 100 + sequence
    if build <= 26:
        raise ValueError(f"tag '{tag}': build {build} isn't above the builds already released (1 to 26)")
    return {
        "tag": tag,
        "version": tag[1:],
        "build": str(build),
        "prerelease": "true" if channel else "false",
        "channel": channel or "",
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <tag>")
    try:
        for key, value in parse(sys.argv[1]).items():
            print(f"{key}={value}")
    except ValueError as err:
        sys.exit(f"error: {err}")
