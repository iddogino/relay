#!/usr/bin/env bash
# Live end-to-end acceptance run against the two configured SSH remotes.
# Discovers one macOS and one Ubuntu host automatically; all remote artifacts
# are namespaced and cleaned up (see docs/remote-project-terminal-v1-spec.md §21).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product relay-e2e >/dev/null

cleanup() {
  # Crash-safe cleanup for any state files this (or a previous) run left.
  for f in .e2e-state/*.json; do
    [ -e "$f" ] || continue
    echo "cleanup: $f"
    .build/debug/relay-e2e cleanup --state "$f" || true
  done
}
trap cleanup EXIT

.build/debug/relay-e2e run
