#!/usr/bin/env python3
"""Inserts (or replaces) one release item in appcast.xml.

Called by the release workflow after a DMG is published and EdDSA-signed.
Idempotent: re-running for the same build number replaces the existing item.
Items are kept newest-first by build number. The result is re-parsed before
writing so a malformed feed can never be committed.
"""
import argparse
import email.utils
import re
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

ITEM_TEMPLATE = """    <item>
      <title>Relay {short_version}</title>
      <link>https://github.com/iddogino/relay/releases/tag/{tag}</link>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
{channel_line}      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--version", required=True, help="CFBundleVersion (monotonic build number)")
    parser.add_argument("--short-version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--channel", default=None)
    parser.add_argument("--min-system", default="15.0")
    args = parser.parse_args()

    if not re.fullmatch(r"[0-9]+", args.version):
        sys.exit(f"error: --version must be a plain integer build number, got {args.version!r}")
    if not re.fullmatch(r"[0-9]+", args.length):
        sys.exit(f"error: --length must be an integer, got {args.length!r}")
    if not re.fullmatch(r"[A-Za-z0-9+/=]+", args.signature):
        sys.exit("error: --signature does not look like base64")

    channel_line = (
        f"      <sparkle:channel>{escape(args.channel)}</sparkle:channel>\n" if args.channel else ""
    )
    item = ITEM_TEMPLATE.format(
        short_version=escape(args.short_version),
        tag=escape(args.tag),
        pub_date=email.utils.formatdate(usegmt=True),
        version=args.version,
        min_system=escape(args.min_system),
        channel_line=channel_line,
        url=escape(args.url, {'"': "&quot;"}),
        length=args.length,
        signature=args.signature,
    )

    with open(args.appcast, encoding="utf-8") as f:
        feed = f.read()
    if "</channel>" not in feed:
        sys.exit("error: appcast has no </channel>")

    # Structural edit: pull out every item block, drop any block for this
    # build number (idempotent re-run), add the new one, sort newest-first,
    # and reassemble. The lazy match cannot cross an item boundary because
    # it stops at the first </item>.
    item_pattern = re.compile(r"    <item>\n.*?    </item>\n", re.S)
    blocks = item_pattern.findall(feed)
    skeleton = item_pattern.sub("", feed)

    def build_number(block: str) -> int:
        m = re.search(r"<sparkle:version>([0-9]+)</sparkle:version>", block)
        return int(m.group(1)) if m else 0

    replaced = any(build_number(b) == int(args.version) for b in blocks)
    blocks = [b for b in blocks if build_number(b) != int(args.version)]
    blocks.append(item)
    blocks.sort(key=build_number, reverse=True)

    feed = skeleton.replace("</channel>", "".join(blocks) + "  </channel>", 1)

    # Never write a feed that doesn't parse.
    try:
        ET.fromstring(feed)
    except ET.ParseError as err:
        sys.exit(f"error: refusing to write malformed appcast: {err}")

    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(feed)
    print(f"appcast: {'replaced' if replaced else 'added'} item for build {args.version} ({args.short_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
