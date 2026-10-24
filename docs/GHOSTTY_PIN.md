# libghostty pin

Relay's terminal is rendered by **libghostty** (Ghostty's embeddable core,
Metal renderer), built from official source and linked statically as
`GhosttyKit.xcframework`.

| | |
|---|---|
| Upstream | https://github.com/ghostty-org/ghostty |
| Pinned ref | upstream `main`, the "tip" nightly of 2026-10-23 (v1.3.1 is still the latest release) |
| Pinned commit | `22f100c6367045bb5fc86172f837047dee2f7670` |
| Zig toolchain | `0.17.0` (exact, SHA-256-verified; fetched locally by the build script) |
| License | MIT (Ghostty branding/icons are **not** used by Relay) |

## Reproducing the build

```sh
Scripts/build-libghostty.sh   # fetches the pinned commit and Zig 0.17.0, builds
Scripts/build-app.sh          # builds Relay.app (links the xcframework)
```

The script verifies the checked-out commit matches the pin and refuses to
build anything else.

## Bumping the pin

An upstream bump must be a deliberate change:

1. Update `GHOSTTY_REF` / `GHOSTTY_COMMIT` (and `ZIG_VERSION` + `ZIG_SHA256`
   to match the new `minimum_zig_version` in Ghostty's `build.zig.zon`; the
   checksum is in https://ziglang.org/download/index.json) in
   `Scripts/build-libghostty.sh`, and this file.
2. Delete `Vendor/ghostty`, re-run `Scripts/build-libghostty.sh`.
3. Re-check the embedding surface used by Relay (the C API in
   `include/ghostty.h` is still evolving): `Sources/Relay/Ghostty/*` is the
   only code that may need updating.
4. Run the terminal smoke tests: unit tests, `Scripts/live-e2e.sh`, and the
   manual UX smoke test (spec §25) before shipping.

## Isolation rules

All libghostty C API usage lives in `Sources/Relay/Ghostty/`
(`GhosttyRuntime.swift`, `TerminalSurfaceView.swift`, `GhosttyInput.swift`).
No Ghostty C types may leak into `RelayCore` or the SwiftUI layer.
