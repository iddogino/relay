#!/usr/bin/env bash
# Independent cleanup after a crashed live E2E run. Safe to run any time:
# it only kills tmux sessions tagged with a recorded run ID and removes
# sentinel-validated temp roots recorded in .e2e-state/.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product relay-e2e >/dev/null

found=0
for f in .e2e-state/*.json; do
  [ -e "$f" ] || continue
  found=1
  echo "cleanup: $f"
  .build/debug/relay-e2e cleanup --state "$f" || true
done
[ "$found" = 1 ] || echo "nothing to clean"
