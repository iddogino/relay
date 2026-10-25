# Vendored swift-nio-ssh

Relay's SSH client (`Sources/RelaySSH`) is built on NIOSSH from
[Joannis/swift-nio-ssh](https://github.com/Joannis/swift-nio-ssh) — the fork
that adds custom private keys (`NIOSSHPrivateKeyProtocol`), which signing
through ssh-agent needs. Apple's upstream doesn't have them.

This directory is that fork at tag **0.3.5**, commit
`791437a67f5394b13060314c778c0f63124803b1`: the `NIOSSH` library target
(`Sources/NIOSSH`) and its license, unchanged except for the patches below. The
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

2. **Announce a maximum packet size the parser accepts**
   (`Sources/NIOSSH/Child Channels/SSHChannelMultiplexer.swift` and
   `SSHChildChannel.swift`, marked `RELAY PATCH`). Channel open messages
   announced `maximumPacketSize` (128 KiB) as the most data the peer may put
   in one packet, while the packet parser refuses any packet of that size or
   more — and a packet carries a header and padding besides its data. A peer
   that fills packets to what was announced (another NIOSSH; Go's
   x/crypto/ssh) broke the connection: a large paste into a terminal on such
   a server killed it. The announcement now leaves 1 KiB of headroom.
   Relay's tests reproduce it (`fullSizePacketsFromTheServerArrive`,
   `aLargeWriteReachesTheProgramWhole`, `aLargeBracketedPasteArrivesWhole`).

## Updating

Copy `Sources/NIOSSH` from the new tag over this one, re-apply the patches
above (drop any the new version already has), and update the commit here.
