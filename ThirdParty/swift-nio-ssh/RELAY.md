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

3. **Hold channel messages during a key re-exchange**
   (`Sources/NIOSSH/NIOSSHHandler.swift` and
   `Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift`,
   marked `RELAY PATCH`). Once a re-exchange starts, a side may send only key
   exchange messages until it has sent its NEWKEYS (RFC 4253 §7.1); the state
   machine enforced that by refusing anything else, so whatever a channel
   wrote meanwhile — data, window adjusts, requests, closes — failed, mostly
   with no promise to notice. OpenSSH servers re-key every 1–4 GB by default
   (or as configured, e.g. hourly), and the first lost window adjust stalled
   that channel for good: a long-lived terminal froze, keystrokes and window
   changes vanished. Channel messages are now held and sent, in order, once
   our NEWKEYS is out. Relay's tests reproduce it against sshd with a tiny
   `RekeyLimit` (`rekeyingMidStreamLosesNothing`,
   `rekeyingMidStreamKeepsTheTerminalWhole`).

4. **Sign key offers off the event loop, and skip a key that can't sign**
   (`Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift`,
   marked `RELAY PATCH`). An offered private key was signed with on the event
   loop, and a signing error failed the authentication. With keys held by
   ssh-agent — where signing can wait for the user (`ssh-add -c`, 1Password,
   Secretive) and can be refused — that froze every connection sharing the
   loop for as long as the agent took, and one declined key ended the sign-in
   with the other keys untried. Offers are now signed on a dispatch queue,
   and a key that fails to sign is passed over for the delegate's next offer.
   Relay's tests reproduce it (`aKeyTheAgentWontSignWithIsPassedOver`).

5. **A preferred order for host key algorithms**
   (`Sources/NIOSSH/SSHClientConfiguration.swift` and
   `Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift`, marked
   `RELAY PATCH`). The client asked for host key algorithms in one fixed
   order, so a server with several host keys presented whichever came first
   in it — not necessarily the one the client had on record. Relay now asks
   first for the types it knows the host by (`SSHConnection`), which is what
   lets a host that presents a key of a type it isn't known by be treated as
   changed rather than new (`KnownHosts.verify`).

6. **A keepalive request** (`Sources/NIOSSH/NIOSSHHandler.swift`,
   `sendKeepalive`, marked `RELAY PATCH`). Only TCP forwarding requests could
   be sent as global requests. A connection through a jump host has no socket
   of its own to detect a dead peer with (TCP keepalive covers the hop to the
   jump host only), so Relay sends OpenSSH's `keepalive@openssh.com` on it
   and closes it when the answers stop (`SSHConnection.startKeepalive`).

## Updating

Copy `Sources/NIOSSH` from the new tag over this one, re-apply the patches
above (drop any the new version already has), and update the commit here.
