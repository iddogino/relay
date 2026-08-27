#!/usr/bin/env bash
# Builds the pinned libghostty (GhosttyKit.xcframework) from vendored source.
# See docs/GHOSTTY_PIN.md for the pin policy.
set -euo pipefail
cd "$(dirname "$0")/.."

GHOSTTY_TAG="v1.3.1"
GHOSTTY_COMMIT="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"
ZIG_VERSION="0.15.2"

GHOSTTY_DIR="Vendor/ghostty"
ZIG_DIR="Vendor/toolchain/zig-aarch64-macos-${ZIG_VERSION}"
ZIG="${ZIG_DIR}/zig"

# 1. Fetch pinned Ghostty source.
if [ ! -d "$GHOSTTY_DIR" ]; then
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty "$GHOSTTY_DIR"
fi
ACTUAL_COMMIT="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$GHOSTTY_COMMIT" ]; then
  echo "error: $GHOSTTY_DIR is at $ACTUAL_COMMIT, expected pinned $GHOSTTY_COMMIT ($GHOSTTY_TAG)." >&2
  echo "Delete Vendor/ghostty and re-run, or update the pin deliberately (see docs/GHOSTTY_PIN.md)." >&2
  exit 1
fi

# 2. Fetch the exact Zig toolchain (kept local to the repo; not installed system-wide).
if [ ! -x "$ZIG" ]; then
  mkdir -p Vendor/toolchain
  TARBALL="zig-aarch64-macos-${ZIG_VERSION}.tar.xz"
  curl -fsSL -o "Vendor/toolchain/${TARBALL}" "https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
  tar -xf "Vendor/toolchain/${TARBALL}" -C Vendor/toolchain
  rm "Vendor/toolchain/${TARBALL}"
fi

# 3. Build the xcframework (native arch, optimized).
(cd "$GHOSTTY_DIR" && "$(pwd)/../../$ZIG" build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast)

echo "Built $GHOSTTY_DIR/macos/GhosttyKit.xcframework"
