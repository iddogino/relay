#!/bin/sh
# Regenerates a language's grammar JSON and vendors its Prism test fixtures.
#
#   ./sync-prism.sh <lang> [<lang> ...]
#
# - Grammar: converted from the npm prismjs package pinned in package.json
#   (see convert-grammars.mjs).
# - Fixtures: copied from a shallow clone of the Prism repo at the tag
#   matching that version (fixtures aren't shipped in the npm package).
#
# Idempotent; run it again to re-sync after bumping the prismjs pin.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(dirname "$SCRIPT_DIR")
FIXTURES_DIR="$PKG_DIR/Tests/RelaySyntaxHighlighterTests/Fixtures"

[ $# -ge 1 ] || { echo "usage: $0 <lang> [<lang> ...]" >&2; exit 1; }

cd "$SCRIPT_DIR"
[ -d node_modules/prismjs ] || npm install --no-audit --no-fund
VERSION=$(node -p "require('prismjs/package.json').version")

CLONE="${PRISM_CLONE:-${TMPDIR:-/tmp}/relay-prism-v$VERSION}"
if [ ! -d "$CLONE/tests/languages" ]; then
    rm -rf "$CLONE"
    git clone --depth 1 --branch "v$VERSION" https://github.com/PrismJS/prism "$CLONE"
fi

# One node process per language: Prism components mutate each other when
# co-loaded (css injects rules into markup, etc.), and the upstream test
# suite loads each language into a FRESH Prism instance. Converting in
# isolation keeps our grammars faithful to what the fixtures expect.
for lang in "$@"; do
    node convert-grammars.mjs "$lang"
done

for lang in "$@"; do
    src="$CLONE/tests/languages/$lang"
    if [ -d "$src" ]; then
        rm -rf "$FIXTURES_DIR/$lang"
        mkdir -p "$FIXTURES_DIR/$lang"
        cp "$src"/*.test "$FIXTURES_DIR/$lang/"
        echo "OK $lang: $(ls "$FIXTURES_DIR/$lang" | wc -l | tr -d ' ') fixtures"
    else
        echo "WARN $lang: no fixture directory in Prism repo" >&2
    fi
done
