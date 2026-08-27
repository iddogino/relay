# Relay

A very small, native Mac app that makes **persistent remote terminal sessions
feel like local terminal tabs**.

```
Remote (from ~/.ssh/config)
└── Project (a folder on that remote)
    └── Session (a persistent tmux session)
```

The terminal is a real [libghostty](https://github.com/ghostty-org/ghostty)
surface (Metal renderer) — your own Ghostty configuration (font, theme,
keybinds) applies automatically. SSH and tmux are invisible implementation
details: if `ssh <alias>` works and the remote has `tmux`, Relay works without
changing the remote machine in any way.

## What it does

- **Remotes** are discovered from `~/.ssh/config` (including `Include`d files).
  Connections always run through `/usr/bin/ssh <alias>`, so keys, agents,
  `ProxyJump`, Tailscale names, `ControlMaster` — everything you configured —
  just works.
- **Projects** pin a folder on a remote, with an optional *launch command*
  (run in every new session — `claude`, `codex`, your worktree bootstrap
  script, anything) and an optional *shutdown command* (run when you archive a
  session — e.g. clean up that worktree).
- **Sessions** are ordinary remote tmux sessions owned by the app. Close the
  laptop, lose Wi-Fi, quit the app — the remote work keeps running. Select the
  session again and Relay reattaches. They stay reachable from any terminal
  too: `ssh host`, `tmux attach -t rterm-…`.

Launch commands receive a stable environment: `RTERM_PROJECT_ID`,
`RTERM_PROJECT_NAME`, `RTERM_PROJECT_PATH`, `RTERM_SESSION_ID`,
`RTERM_SESSION_NAME`, `RTERM_REMOTE` (+ `RTERM_SHUTDOWN_REASON=archive` for
shutdown commands).

**Archive Session** (⌘⇧E) ends a session cleanly: detach → kill the tmux
session → run your shutdown command (with retry if it fails). **Kill Session**
is the force escape hatch — it skips the shutdown command.

## Building

Requirements: macOS 15+, Xcode 26 (Swift 6). No third-party dependencies
besides pinned libghostty (built from source, see
[docs/GHOSTTY_PIN.md](docs/GHOSTTY_PIN.md)).

```sh
Scripts/build-libghostty.sh   # once: fetch pinned Ghostty + Zig, build GhosttyKit
Scripts/build-app.sh          # build build/Relay.app (release)
```

## Testing

```sh
swift test              # unit tests (config parsing, quoting, codecs, persistence)
Scripts/live-e2e.sh     # live acceptance run against your two configured remotes
                        # (fully namespaced; cleans up after itself)
Scripts/live-e2e-cleanup.sh   # independent cleanup if a run crashed
```

## Design notes

- `Sources/RelayCore` — domain model, `RuntimeProvider` abstraction, the
  SSH+tmux provider, persistence. No AppKit, no libghostty.
- `Sources/Relay` — the app: SwiftUI UI, the libghostty adapter
  (`Ghostty/`), and the attach/reconnect controller.
- One terminal attachment at a time: switching sessions detaches the previous
  one locally (the remote session keeps running). Idle footprint stays tiny.
- Management commands run as one-shot `ssh` invocations with `BatchMode=yes`,
  delivered to a remote `/bin/sh -s` over stdin — the remote login shell never
  parses generated script text, and every dynamic value is POSIX-quoted.
- The app only ever touches tmux sessions carrying its own `@rterm_*`
  metadata; your other tmux sessions are invisible to it.
- Measured footprint (Release, M2 Max, macOS 15.7): idle CPU ≈ 0% with no
  terminal and ≈ 0.4% with one attached idle terminal; ~102 MB RSS idle,
  ~115 MB with one attached terminal.
- Known cosmetic issue: macOS logs one "reentrant operation in its
  NSTableView delegate" warning at launch (SwiftUI sidebar internals; no
  functional impact).

Spec: [docs/remote-project-terminal-v1-spec.md](docs/remote-project-terminal-v1-spec.md).
