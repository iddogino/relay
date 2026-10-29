# libghostty pin

Relay's terminal is rendered by **libghostty** (Ghostty's embeddable core,
Metal renderer), built from official source and linked statically as
`GhosttyKit.xcframework`.

| | |
|---|---|
| Upstream | https://github.com/ghostty-org/ghostty |
| Pinned ref | upstream `main`, the "tip" nightly of 2026-10-23 (v1.3.1 is still the latest release) |
| Pinned commit | `22f100c6367045bb5fc86172f837047dee2f7670` |
| Zig toolchain | `0.17.0` (exact, SHA-256-verified; fetched locally by the build script, which patches its standard library) |
| License | MIT (Ghostty branding/icons are **not** used by Relay) |

## Reproducing the build

```sh
Scripts/build-libghostty.sh              # fetches the pinned commit and Zig 0.17.0, applies patches, builds
Scripts/build-libghostty.sh --universal  # also the x86_64 Mac, iOS and iOS Simulator slices
Scripts/build-libghostty.sh --test       # the patches' Zig unit tests instead of a build
Scripts/build-app.sh                     # builds Relay.app (links the xcframework)
```

The default build has this Mac's architecture only, which is all the Mac
app's development builds need. `--universal` adds the slices the iOS app
links (`ios-arm64` and an arm64-only `ios-arm64-simulator`) and an x86_64
Mac slice; the `ios` CI job builds it and compiles the package's `RelayKit`
product for iOS.

The script verifies the checked-out commit matches the pin and refuses to
build anything else.

## Relay's patches

`patches/ghostty/*.patch` are applied, in order, on top of the pinned commit
(a stamp in `Vendor/ghostty/.relay-patches` makes re-runs no-ops and
re-applies a changed patch set from a clean checkout).

- **0001 — manual termio backend.** A surface mode with no subprocess:
  `io_mode = GHOSTTY_SURFACE_IO_MANUAL` in `ghostty_surface_config_s`, output
  fed with `ghostty_surface_write_output`, the terminal's writes and grid size
  delivered to `io_write_cb` / `io_resize_cb`, and the program's end reported
  with `ghostty_surface_report_exit` (handled like a child process exiting).
  Exec surfaces are unchanged. Relay uses it for terminals over its built-in
  SSH client (`Sources/RelayGhosttyIO`). Upstream had a similar, unmerged
  attempt (ghostty-org/ghostty#10484).

  Tests: Zig unit tests in `src/termio/Manual.zig` (`--test` above, and the
  `ghostty-patch` CI job); C-API tests on real surfaces
  (`Tests/RelayGhosttyIOTests/ManualIOSurfaceTests.swift`); and end-to-end
  terminals over SSH against an in-process server and a real `sshd`
  (`TerminalOverSSHTests.swift`).

- **0002 — iOS build.** Upstream stopped building the full libghostty for
  iOS on 2026-08-12 (ghostty-org/ghostty#13760; only libghostty-vt is still
  compiled for iOS), though the iOS code paths remain (the Metal renderer on
  a `UIView`, `GHOSTTY_PLATFORM_IOS`, `NullPty`). This restores the iOS slices
  of `-Dxcframework-target=universal` that commit removed, passes `-fblocks`
  to translate-c for iOS (the iOS SDK's headers declare blocks, and Aro
  enables them by itself only for macOS), and sizes fonts at 72 dpi on iOS as
  on macOS (iOS got 96, a third too large). Relay owns this build path now:
  nothing upstream checks it.

### Zig

`patches/zig/*.patch` are applied to the fetched toolchain's standard
library, with a stamp in it the same way (a toolchain patched with a
different set is fetched again).

- **0001 — `std.Io.Threaded` on iOS.** In Zig 0.17.0, `NullFile` has no `fd`
  on iOS, yet `spawnDarwin` reads it, so any iOS build that uses
  `Io.Threaded` (libghostty does, in `src/global.zig`) fails to compile.
  Zig's master branch has the same fix. Drop the patch once the Zig pin
  includes it.

To change a patch: edit `Vendor/ghostty` (after one script run), then
regenerate it with `git -C Vendor/ghostty add -N <new files>` and
`git -C Vendor/ghostty diff` (keeping the patch's description header).

## Bumping the pin

An upstream bump must be a deliberate change:

1. Update `GHOSTTY_REF` / `GHOSTTY_COMMIT` (and `ZIG_VERSION` + `ZIG_SHA256`
   to match the new `minimum_zig_version` in Ghostty's `build.zig.zon`; the
   checksum is in https://ziglang.org/download/index.json) in
   `Scripts/build-libghostty.sh`, and this file.
2. Delete `Vendor/ghostty`, re-run `Scripts/build-libghostty.sh`. If a
   patch no longer applies, rebase it onto the new pin (and re-run
   `--test`). Build `--universal` too: the iOS slices are Relay's to keep
   building. With a new Zig version, check whether `patches/zig` is still
   needed (or still applies).
3. Re-check the embedding surface used by Relay (the C API in
   `include/ghostty.h` is still evolving): `Sources/Relay/Ghostty/*` is the
   only code that may need updating.
4. Run the terminal smoke tests: unit tests, `Scripts/live-e2e.sh`, and the
   manual UX smoke test (spec §25) before shipping.

## Isolation rules

All libghostty C API usage lives in `Sources/Relay/Ghostty/`
(`GhosttyRuntime.swift`, `TerminalSurfaceView.swift`, `GhosttyInput.swift`)
and `Sources/RelayGhosttyIO/` (manual I/O). No Ghostty C types may leak into
`RelayCore` or the SwiftUI layer.
