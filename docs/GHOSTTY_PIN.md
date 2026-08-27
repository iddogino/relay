# libghostty pin

Relay's terminal is rendered by **libghostty** (Ghostty's embeddable core,
Metal renderer), built from official source and linked statically as
`GhosttyKit.xcframework`.

| | |
|---|---|
| Upstream | https://github.com/ghostty-org/ghostty |
| Pinned tag | `v1.3.1` |
| Pinned commit | `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` |
| Zig toolchain | `0.15.2` (exact; fetched locally by the build script) |
| License | MIT (Ghostty branding/icons are **not** used by Relay) |

## Reproducing the build

```sh
Scripts/build-libghostty.sh   # clones the pin, fetches Zig 0.15.2, builds
Scripts/build-app.sh          # builds Relay.app (links the xcframework)
```

The script verifies the checked-out commit matches the pin and refuses to
build anything else.

## Bumping the pin

An upstream bump must be a deliberate change:

1. Update `GHOSTTY_TAG` / `GHOSTTY_COMMIT` (and `ZIG_VERSION` to match the new
   `minimum_zig_version` in Ghostty's `build.zig.zon`) in
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
