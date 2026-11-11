#!/usr/bin/env bash
# Builds the prebuilt tmux binaries Relay bundles and uploads to hosts that
# have no tmux of their own, plus the terminfo entries they need.
#
#   Scripts/build-tmux.sh             build everything into build/tmux/, then verify
#   Scripts/build-tmux.sh --no-verify skip the run checks (Docker/debian and local)
#   Scripts/build-tmux.sh --linux     only what needs Docker: the Linux builds and
#                                     terminfo, verified (runs on Linux too)
#   Scripts/build-tmux.sh --no-docker the rest, where there's no Docker: the Linux
#                                     pieces must already be in build/tmux-work/
#                                     (from --linux, here or copied from where it
#                                     ran), and aren't verified again
#
# The last two are how a release is built (.github/workflows): --linux on a
# Linux runner, --no-docker on the Mac that builds the app.
#
# Outputs (build/tmux/):
#   tmux-linux-x86_64.gz, tmux-linux-aarch64.gz  fully static (musl), built in
#                                                 Docker with alpine
#   tmux-darwin-universal.gz                      arm64+x86_64, macOS 12+, links
#                                                 only /usr/lib system libraries;
#                                                 libevent and utf8proc are static
#   terminfo.tar.gz                               xterm-256color, screen,
#                                                 screen-256color, tmux,
#                                                 tmux-256color, in both letter
#                                                 (x/…) and hex (78/…) dirs
#   manifest.json                                 sizes and hashes; tmux entries
#                                                 hash the *uncompressed* binary
#
# Downloads and intermediate builds are cached in build/tmux-work/; delete it to
# start clean. Needs Docker (OrbStack is fine) and Xcode's command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERIFY=1
STAGE="all"
USE_DOCKER=1
for arg in "$@"; do
  case "$arg" in
    --no-verify) VERIFY=0 ;;
    --linux) STAGE="linux" ;;
    --no-docker) USE_DOCKER=0 ;;
    *) echo "error: unknown option $arg" >&2; exit 2 ;;
  esac
done

TMUX_VERSION="3.5a"
TMUX_SHA256="16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951"
LIBEVENT_VERSION="2.1.12-stable"
LIBEVENT_SHA256="92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb"
UTF8PROC_VERSION="2.9.0"
UTF8PROC_SHA256="18c1626e9fc5a2e192311e36b3010bfc698078f692888940f1fa150547abb0c1"
# Only for terminfo.src and a tic that writes the legacy (16-bit) format.
NCURSES_VERSION="6.5"
NCURSES_SHA256="136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"

ALPINE_IMAGE="alpine:3.20"
DEBIAN_IMAGE="debian:bookworm-slim"
MACOS_MIN="12.0"
TERMINFO_ENTRIES="xterm-256color,screen,screen-256color,tmux,tmux-256color"
# What new panes get as TERM; terminfo.tar.gz ships it.
DEFAULT_TERM="tmux-256color"

DOCKER="${DOCKER:-$(command -v docker || echo /usr/local/bin/docker)}"
WORK="$ROOT/build/tmux-work"
DL="$WORK/dl"
OUT="$ROOT/build/tmux"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
export TMUX_VERSION LIBEVENT_VERSION NCURSES_VERSION TERMINFO_ENTRIES DEFAULT_TERM JOBS
mkdir -p "$DL" "$OUT"

# 1. Fetch pinned sources; a hash mismatch is fatal, never re-downloaded over.
fetch() { # name url sha256
  local file="$DL/$1"
  if [ ! -f "$file" ]; then
    echo "Downloading $1"
    curl -fsSL --retry 3 -o "$file.part" "$2"
    mv "$file.part" "$file"
  fi
  local actual
  actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$actual" != "$3" ]; then
    echo "error: $file has sha256 $actual, expected pinned $3." >&2
    exit 1
  fi
}
fetch "tmux-$TMUX_VERSION.tar.gz" \
  "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz" "$TMUX_SHA256"
fetch "libevent-$LIBEVENT_VERSION.tar.gz" \
  "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz" "$LIBEVENT_SHA256"
fetch "utf8proc-$UTF8PROC_VERSION.tar.gz" \
  "https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v$UTF8PROC_VERSION.tar.gz" "$UTF8PROC_SHA256"
fetch "ncurses-$NCURSES_VERSION.tar.gz" \
  "https://invisible-island.net/archives/ncurses/ncurses-$NCURSES_VERSION.tar.gz" "$NCURSES_SHA256"

# A stamp per build dir records the pins it was built from, so re-runs skip
# finished work and a changed pin rebuilds from scratch.
PIN_STAMP="tmux=$TMUX_SHA256 libevent=$LIBEVENT_SHA256 utf8proc=$UTF8PROC_SHA256 ncurses=$NCURSES_SHA256 alpine=$ALPINE_IMAGE macos=$MACOS_MIN term=$DEFAULT_TERM"
is_built() { [ "$(cat "$1/.stamp" 2>/dev/null || true)" = "$PIN_STAMP" ]; }
fresh_dir() { rm -rf "$1"; mkdir -p "$1"; }
need_docker() { # what
  if [ "$USE_DOCKER" = 0 ]; then
    echo "error: $1 isn't built for these pins, and --no-docker can't build it." >&2
    echo "Run Scripts/build-tmux.sh --linux where there's Docker, and bring build/tmux-work/ here." >&2
    exit 1
  fi
}

# 2. Linux: static musl builds inside alpine, one container per arch.
build_linux() { # docker-platform arch-name
  local dir="$WORK/linux-$2"
  if is_built "$dir"; then echo "linux-$2: up to date"; return; fi
  need_docker "tmux for linux-$2"
  fresh_dir "$dir"
  echo "Building tmux for linux-$2"
  "$DOCKER" run --rm --platform "$1" \
    -v "$DL:/dl:ro" -v "$dir:/work" \
    -e TMUX_VERSION -e LIBEVENT_VERSION -e DEFAULT_TERM -e JOBS \
    "$ALPINE_IMAGE" /bin/sh -euc '
      apk add --no-cache -q build-base linux-headers bison ncurses-dev ncurses-static >/dev/null
      cd /tmp
      tar xzf /dl/libevent-$LIBEVENT_VERSION.tar.gz
      (cd libevent-$LIBEVENT_VERSION &&
        ./configure -q --prefix=/tmp/prefix --disable-shared --enable-static \
          --disable-openssl --disable-samples --disable-libevent-regress &&
        make -s -j$JOBS && make -s install) >/dev/null 2>&1
      tar xzf /dl/tmux-$TMUX_VERSION.tar.gz
      cd tmux-$TMUX_VERSION
      PKG_CONFIG_PATH=/tmp/prefix/lib/pkgconfig ./configure -q \
        --with-TERM="$DEFAULT_TERM" LDFLAGS=-static >/dev/null
      make -s -j$JOBS >/dev/null 2>&1
      strip tmux
      cp tmux /work/tmux
    '
  echo "$PIN_STAMP" > "$dir/.stamp"
}
build_linux linux/amd64 x86_64
build_linux linux/arm64 aarch64

# 3. terminfo: compiled with an ABI-5 tic, which writes the legacy 16-bit
# format (numbers clamp to 32767) that macOS's ncurses 5.7 can read; ncurses 6
# tic would write pairs#65536 in the extended-number format instead. Laid out
# in letter dirs (Linux) and hex dirs (macOS, case-insensitive filesystems).
TERMINFO_DIR="$WORK/terminfo"
if is_built "$TERMINFO_DIR"; then
  echo "terminfo: up to date"
else
  need_docker "terminfo"
  fresh_dir "$TERMINFO_DIR"
  echo "Compiling terminfo"
  "$DOCKER" run --rm -v "$DL:/dl:ro" -v "$TERMINFO_DIR:/work" \
    -e NCURSES_VERSION -e TERMINFO_ENTRIES -e JOBS \
    "$ALPINE_IMAGE" /bin/sh -euc '
      apk add --no-cache -q build-base tar gzip >/dev/null
      cd /tmp
      tar xzf /dl/ncurses-$NCURSES_VERSION.tar.gz
      cd ncurses-$NCURSES_VERSION
      ./configure -q --with-abi-version=5 --disable-ext-colors --without-shared \
        --without-cxx --without-cxx-binding --without-ada --without-tests \
        --without-manpages --without-progs-docs >/dev/null 2>&1
      make -s -j$JOBS -C include >/dev/null 2>&1
      make -s -j$JOBS -C ncurses >/dev/null 2>&1
      make -s -j$JOBS -C progs tic >/dev/null 2>&1
      mkdir -p /tmp/ti
      ./progs/tic -x -o /tmp/ti -e "$TERMINFO_ENTRIES" misc/terminfo.src
      cd /tmp/ti
      for f in */*; do
        hex=$(printf "%02x" "'\''${f%%/*}")
        mkdir -p "$hex" && cp "$f" "$hex/"
      done
      tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -cf - * | gzip -9 -n > /work/terminfo.tar.gz
    '
  echo "$PIN_STAMP" > "$TERMINFO_DIR/.stamp"
fi

# The Linux pieces, packaged: all the --linux stage makes.
gzip -9 -n -c "$WORK/linux-x86_64/tmux" > "$OUT/tmux-linux-x86_64.gz"
gzip -9 -n -c "$WORK/linux-aarch64/tmux" > "$OUT/tmux-linux-aarch64.gz"
cp "$TERMINFO_DIR/terminfo.tar.gz" "$OUT/terminfo.tar.gz"

# Verifying a Linux build: it starts a server on a private socket and lists
# it, reading only the bundled terminfo. A detached server never opens a
# terminal, so the check also attaches a client (under script(1) for a pty),
# which is what reads terminfo. The throwaway container's own terminfo
# (debian's ncurses-base ships all five entries) is deleted first, so only
# the bundled entries can satisfy it.
verify_linux() { # docker-platform arch-name
  echo "Verifying linux-$2 in $DEBIAN_IMAGE"
  "$DOCKER" run --rm --platform "$1" -v "$OUT:/out:ro" "$DEBIAN_IMAGE" /bin/sh -euc '
    rm -rf /etc/terminfo /lib/terminfo /usr/share/terminfo /usr/lib/terminfo
    mkdir -p /tmp/ti && tar xzf /out/terminfo.tar.gz -C /tmp/ti
    gzip -dc /out/tmux-linux-'"$2"'.gz > /tmp/tmux && chmod +x /tmp/tmux
    /tmp/tmux -V
    attach() { # TERM; prints the client exit code and any terminal error
      TERM=$1 script -qec "/tmp/tmux -S /tmp/a -f /dev/null new-session true; echo rc=\$?" /dev/null </dev/null \
        | tr -d "\033\r" | grep -aoE "missing or unsuitable terminal: [^ ]*|rc=[0-9]+" | tr "\n" " "
    }
    out=$(attach tmux-256color)
    case "$out" in *"rc=0"*) echo "control: tmux-256color resolved without the bundle" >&2; exit 1 ;; esac
    echo "control without TERMINFO_DIRS: $out"
    export TERMINFO_DIRS=/tmp/ti
    for term in xterm-256color tmux-256color screen-256color; do
      out=$(attach $term)
      echo "attach TERM=$term: $out"
      case "$out" in *"rc=0"*) ;; *) exit 1 ;; esac
      TERM=$term /tmp/tmux -S /tmp/s -f /dev/null new-session -d "sleep 5"
      TERM=$term /tmp/tmux -S /tmp/s ls
      [ "$(/tmp/tmux -S /tmp/s show -gv default-terminal)" = tmux-256color ]
      /tmp/tmux -S /tmp/s kill-server
    done
  '
}

if [ "$STAGE" = "linux" ]; then
  if [ "$VERIFY" = 1 ]; then
    verify_linux linux/amd64 x86_64
    verify_linux linux/arm64 aarch64
  fi
  echo "Done (Linux builds and terminfo; run with --no-docker on a Mac for the rest):"
  ls -l "$OUT"
  exit 0
fi

# 4. macOS: per-arch clang builds against static libevent/utf8proc, then lipo.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
build_darwin() { # arch
  local dir="$WORK/darwin-$1" host
  if is_built "$dir"; then echo "darwin-$1: up to date"; return; fi
  fresh_dir "$dir"
  echo "Building tmux for darwin-$1"
  case "$1" in arm64) host=aarch64-apple-darwin ;; x86_64) host=x86_64-apple-darwin ;; esac
  local cc="$(xcrun --find clang) -arch $1 -mmacosx-version-min=$MACOS_MIN -isysroot $SDK"
  local prefix="$dir/prefix"
  mkdir -p "$prefix/lib" "$prefix/include"
  (
    cd "$dir"
    tar xzf "$DL/libevent-$LIBEVENT_VERSION.tar.gz"
    cd "libevent-$LIBEVENT_VERSION"
    ./configure -q --host="$host" --prefix="$prefix" CC="$cc" \
      --disable-shared --enable-static --disable-openssl --disable-samples \
      --disable-libevent-regress >/dev/null
    make -s -j"$JOBS" >/dev/null 2>&1 && make -s install >/dev/null
  )
  (
    cd "$dir"
    tar xzf "$DL/utf8proc-$UTF8PROC_VERSION.tar.gz"
    cd "utf8proc-$UTF8PROC_VERSION"
    $cc -O2 -DUTF8PROC_STATIC -c utf8proc.c -o utf8proc.o
    xcrun ar rcs "$prefix/lib/libutf8proc.a" utf8proc.o
    cp utf8proc.h "$prefix/include/"
  )
  (
    cd "$dir"
    tar xzf "$DL/tmux-$TMUX_VERSION.tar.gz"
    cd "tmux-$TMUX_VERSION"
    # No pkg-config: utf8proc is handed over explicitly, and the libevent and
    # ncurses checks fall back to plain -l searches, which find only our static
    # libs in $prefix and the SDK's system ncurses.
    ./configure -q --host="$host" --enable-utf8proc --with-TERM="$DEFAULT_TERM" \
      CC="$cc" PKG_CONFIG=/usr/bin/false \
      LIBUTF8PROC_CFLAGS="-I$prefix/include -DUTF8PROC_STATIC" LIBUTF8PROC_LIBS="-L$prefix/lib -lutf8proc" \
      CPPFLAGS="-I$prefix/include -DUTF8PROC_STATIC" LDFLAGS="-L$prefix/lib" >/dev/null
    make -s -j"$JOBS" >/dev/null 2>&1
    xcrun strip tmux
    cp tmux "$dir/tmux"
  )
  echo "$PIN_STAMP" > "$dir/.stamp"
}
build_darwin arm64
build_darwin x86_64

DARWIN_UNIVERSAL="$WORK/tmux-darwin-universal"
xcrun lipo -create -output "$DARWIN_UNIVERSAL" "$WORK/darwin-arm64/tmux" "$WORK/darwin-x86_64/tmux"
codesign -f -s - "$DARWIN_UNIVERSAL" 2>/dev/null

# Only system libraries from /usr/lib may be linked; nothing from the build tree.
bad_libs="$(xcrun otool -L "$DARWIN_UNIVERSAL" | awk '!/:$/ && $1 !~ /^\/usr\/lib\// {print $1}')"
if [ -n "$bad_libs" ]; then
  echo "error: tmux-darwin-universal links non-system libraries:" >&2
  echo "$bad_libs" >&2
  exit 1
fi

# 5. Package and write the manifest.
gzip -9 -n -c "$DARWIN_UNIVERSAL" > "$OUT/tmux-darwin-universal.gz"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fsize() { stat -f %z "$1"; }
tmux_entry() { # gz-name uncompressed-path
  printf '    "%s": { "uncompressedSha256": "%s", "uncompressedSize": %s, "size": %s }' \
    "$1" "$(sha "$2")" "$(fsize "$2")" "$(fsize "$OUT/$1")"
}
{
  echo '{'
  echo "  \"version\": \"$TMUX_VERSION\","
  echo '  "files": {'
  tmux_entry tmux-linux-x86_64.gz "$WORK/linux-x86_64/tmux"; echo ','
  tmux_entry tmux-linux-aarch64.gz "$WORK/linux-aarch64/tmux"; echo ','
  tmux_entry tmux-darwin-universal.gz "$DARWIN_UNIVERSAL"; echo ','
  printf '    "terminfo.tar.gz": { "sha256": "%s", "size": %s }\n' \
    "$(sha "$OUT/terminfo.tar.gz")" "$(fsize "$OUT/terminfo.tar.gz")"
  echo '  }'
  echo '}'
} > "$OUT/manifest.json"

# 6. Verify (the Linux builds as above, where there's Docker).
if [ "$VERIFY" = 1 ]; then
  if [ "$USE_DOCKER" = 1 ]; then
    verify_linux linux/amd64 x86_64
    verify_linux linux/arm64 aarch64
  fi

  if [ "$(uname -m)" = arm64 ]; then
    echo "Verifying darwin-arm64"
    vdir="$(mktemp -d)"
    trap 'rm -rf "$vdir"' EXIT
    mkdir -p "$vdir/ti" && tar xzf "$OUT/terminfo.tar.gz" -C "$vdir/ti"
    gzip -dc "$OUT/tmux-darwin-universal.gz" > "$vdir/tmux" && chmod +x "$vdir/tmux"
    codesign -v "$vdir/tmux"
    "$vdir/tmux" -V
    # macOS ships its own tmux-256color; make sure ours is the one read.
    TERMINFO_DIRS="$vdir/ti" /usr/bin/infocmp tmux-256color | head -1 | grep -qF "$vdir/ti/" || {
      echo "error: macOS ncurses did not read the bundled tmux-256color" >&2; exit 1; }
    (
      export TERMINFO_DIRS="$vdir/ti" TERM=tmux-256color
      "$vdir/tmux" -S "$vdir/s" -f /dev/null new-session -d "sleep 5"
      "$vdir/tmux" -S "$vdir/s" ls
      "$vdir/tmux" -S "$vdir/s" kill-server
    )
  fi
fi

echo "Done:"
ls -l "$OUT"
