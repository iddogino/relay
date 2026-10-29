#!/usr/bin/env bash
# Builds the pinned libghostty (GhosttyKit.xcframework) from vendored source,
# with Relay's patches (patches/ghostty/) applied. See docs/GHOSTTY_PIN.md.
#
#   Scripts/build-libghostty.sh              build the xcframework (this Mac's arch)
#   Scripts/build-libghostty.sh --universal  also x86_64 Macs, iOS and the iOS Simulator
#   Scripts/build-libghostty.sh --test       run the patches' Zig unit tests instead
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

MODE="build"
XCFRAMEWORK_TARGET="native"
for arg in "$@"; do
  case "$arg" in
    --test) MODE="test" ;;
    --universal) XCFRAMEWORK_TARGET="universal" ;;
    *) echo "error: unknown option $arg" >&2; exit 2 ;;
  esac
done

# Pinned to an upstream main commit (the "tip" nightly of 2026-10-23):
# v1.3.1 is still the latest release, and the pty-less backend work
# targets current main. See docs/GHOSTTY_PIN.md.
GHOSTTY_REF="tip-2026-10-23"
GHOSTTY_COMMIT="22f100c6367045bb5fc86172f837047dee2f7670"
ZIG_VERSION="0.17.0"
ZIG_SHA256="b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a"

GHOSTTY_DIR="Vendor/ghostty"
ZIG_DIR="Vendor/toolchain/zig-aarch64-macos-${ZIG_VERSION}"
ZIG="${ZIG_DIR}/zig"

# 1. Fetch pinned Ghostty source.
if [ ! -d "$GHOSTTY_DIR" ]; then
  git init -q "$GHOSTTY_DIR"
  git -C "$GHOSTTY_DIR" remote add origin https://github.com/ghostty-org/ghostty
  git -C "$GHOSTTY_DIR" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$GHOSTTY_DIR" checkout -q --detach FETCH_HEAD
fi
ACTUAL_COMMIT="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$GHOSTTY_COMMIT" ]; then
  echo "error: $GHOSTTY_DIR is at $ACTUAL_COMMIT, expected pinned $GHOSTTY_COMMIT ($GHOSTTY_REF)." >&2
  echo "Delete Vendor/ghostty and re-run, or update the pin deliberately (see docs/GHOSTTY_PIN.md)." >&2
  exit 1
fi

# 1b. Apply Relay's patches, in order, to the pinned tree. A stamp records
# which patch set the working tree carries: re-runs are no-ops, and a changed
# patch set is re-applied from a clean checkout of the pin.
PATCH_STAMP="$GHOSTTY_DIR/.relay-patches"
PATCH_SUM="$(cat patches/ghostty/*.patch | shasum -a 256 | cut -d' ' -f1)"
if [ "$(cat "$PATCH_STAMP" 2>/dev/null || true)" != "$PATCH_SUM" ]; then
  git -C "$GHOSTTY_DIR" reset -q --hard "$GHOSTTY_COMMIT"
  git -C "$GHOSTTY_DIR" clean -fdq -- src include
  for patch in patches/ghostty/*.patch; do
    echo "Applying $patch"
    git -C "$GHOSTTY_DIR" apply --whitespace=nowarn "$(pwd)/$patch"
  done
  echo "$PATCH_SUM" > "$PATCH_STAMP"
fi

# 2. Fetch the exact Zig toolchain (kept local to the repo; not installed
# system-wide). Relay patches its standard library (patches/zig/); a stamp
# records the patch set, and a toolchain carrying a different one is
# fetched again.
ZIG_STAMP="$ZIG_DIR/.relay-patches"
ZIG_PATCH_SUM="$(cat patches/zig/*.patch | shasum -a 256 | cut -d' ' -f1)"
if [ -f "$ZIG_STAMP" ] && [ "$(cat "$ZIG_STAMP")" != "$ZIG_PATCH_SUM" ]; then
  rm -rf "$ZIG_DIR"
fi
if [ ! -x "$ZIG" ]; then
  mkdir -p Vendor/toolchain
  TARBALL="zig-aarch64-macos-${ZIG_VERSION}.tar.xz"
  curl -fsSL -o "Vendor/toolchain/${TARBALL}" "https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
  echo "${ZIG_SHA256}  Vendor/toolchain/${TARBALL}" | shasum -a 256 -c - >/dev/null || {
    echo "error: Zig tarball checksum mismatch." >&2
    rm -f "Vendor/toolchain/${TARBALL}"
    exit 1
  }
  tar -xf "Vendor/toolchain/${TARBALL}" -C Vendor/toolchain
  rm "Vendor/toolchain/${TARBALL}"
fi
if [ ! -f "$ZIG_STAMP" ]; then
  for patch in patches/zig/*.patch; do
    echo "Applying $patch"
    patch -p1 -s --forward -d "$ZIG_DIR" < "$patch"
  done
  echo "$ZIG_PATCH_SUM" > "$ZIG_STAMP"
fi

# 3a. Or run the patches' unit tests (every test whose name mentions Manual).
if [ "$MODE" = "test" ]; then
  (cd "$GHOSTTY_DIR" && "$ROOT/$ZIG" build test -Dtest-filter=Manual --summary all)
  exit 0
fi

# 3. Build the xcframework (optimized).
(cd "$GHOSTTY_DIR" && "$ROOT/$ZIG" build -Demit-macos-app=false -Dxcframework-target="$XCFRAMEWORK_TARGET" -Doptimize=ReleaseFast)

echo "Built $GHOSTTY_DIR/macos/GhosttyKit.xcframework"
