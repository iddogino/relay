# Vendored swift-nio-ssh

Relay's SSH client (`Sources/RelaySSH`) is built on NIOSSH from
[Joannis/swift-nio-ssh](https://github.com/Joannis/swift-nio-ssh) — the fork
that adds custom private keys (`NIOSSHPrivateKeyProtocol`), which signing
through ssh-agent needs. Apple's upstream doesn't have them.

This directory is that fork at tag **0.3.5**, commit
`791437a67f5394b13060314c778c0f63124803b1`: the `NIOSSH` library target
(`Sources/NIOSSH`) and its license, unchanged except for the patch below. The
example executables, tests, and tooling are left out; `Package.swift` is
trimmed to match.

## Patches

1. **No window adjust after a local close**
   (`Sources/NIOSSH/Child Channels/SSHChildChannel.swift`, marked
   `RELAY PATCH`). The fork predates upstream's fix
   ([apple/swift-nio-ssh#143](https://github.com/apple/swift-nio-ssh/pull/143),
   "Avoid sending window update messages if locally closed"): after a channel
   sends its close, data the peer sent meanwhile can still be delivered, and
   the window adjust that delivery triggers is a precondition failure — a
   crash whenever a terminal (or a cancelled command) is closed while output
   is streaming. Relay's tests reproduce it
   (`closingWhileTheSessionOpensLeavesNothingBehind`,
   `closingDuringAFloodNeverCrashes`).

## Updating

Copy `Sources/NIOSSH` from the new tag over this one, re-apply the patches
above (drop any the new version already has), and update the commit here.
