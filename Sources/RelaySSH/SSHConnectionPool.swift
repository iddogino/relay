import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// Shares authenticated connections between commands: one handshake per
/// host instead of one per command, and up to `maxChannelsPerConnection`
/// commands at once on each (OpenSSH's sshd allows 10 sessions per
/// connection by default).
public actor SSHConnectionPool {
    public static let shared = SSHConnectionPool()

    public struct Options: Sendable {
        public var connectTimeout: TimeAmount = .seconds(10)
        /// Key exchange and authentication, once connected.
        public var handshakeTimeout: TimeAmount = .seconds(20)
        public var maxChannelsPerConnection = 8
        public var idleTimeout: Duration = .seconds(120)
        /// How long a server may take to accept a terminal's pty and
        /// program.
        public var terminalStartTimeout: TimeAmount = .seconds(15)
        /// How long a server may take to confirm a new channel.
        public var channelOpenTimeout: TimeAmount = .seconds(10)
        public var knownHostsFiles = KnownHosts.defaultFiles
        public var agent: SSHAgent? = SSHAgent.fromEnvironment()
        public var defaultKeyFiles = ["~/.ssh/id_ed25519", "~/.ssh/id_ecdsa"]
        /// Relay's own keys, for `.storedKey` credentials.
        public var keyStore: (any SSHKeyStore)?

        public init() {}
    }

    private final class Slot {
        let connection: SSHConnection
        var activeChannels = 0
        var lastUsed = ContinuousClock.now
        /// Set when a channel couldn't be opened: no new work goes here.
        var retired = false

        init(connection: SSHConnection) {
            self.connection = connection
        }
    }

    private let options: Options
    private let group: EventLoopGroup
    private var slots: [SSHTarget: [Slot]] = [:]
    private var connecting: [SSHTarget: Task<Void, Error>] = [:]

    public init(options: Options = Options(), group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.options = options
        self.group = group
    }

    public enum ExecError: Error, Sendable {
        case timedOut
    }

    /// Runs `command` on `target` with `stdin` delivered and closed.
    /// Throws `SSHClientError` for failures before or outside the command
    /// (a command's own failure is a non-zero `exitCode`), `ExecError.timedOut`,
    /// or `CancellationError`.
    public func exec(
        target: SSHTarget,
        command: String,
        stdin: Data,
        environment: [(String, String)] = [],
        timeout: Duration,
        onStdout: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SSHExecResult {
        try await exec(
            target: target, command: command, input: .data(stdin), environment: environment, timeout: timeout,
            onStdout: onStdout)
    }

    /// `exec` with stdin from `input`; with `retainStdout` false, output
    /// only goes to `onStdout` (the result's stdout stays empty) — for
    /// output too big to hold, like a downloaded file.
    public func exec(
        target: SSHTarget,
        command: String,
        input: SSHExecInput,
        environment: [(String, String)] = [],
        timeout: Duration,
        retainStdout: Bool = true,
        onStdout: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SSHExecResult {
        try await withThrowingTaskGroup(of: SSHExecResult.self) { group in
            group.addTask {
                try await self.execWithRetry(
                    target: target, command: command, input: input, environment: environment,
                    retainStdout: retainStdout, onStdout: onStdout)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ExecError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func execWithRetry(
        target: SSHTarget,
        command: String,
        input: SSHExecInput,
        environment: [(String, String)],
        retainStdout: Bool,
        onStdout: (@Sendable (Data) -> Void)?,
        isRetry: Bool = false
    ) async throws -> SSHExecResult {
        let (slot, reused) = try await acquire(target)
        do {
            let result = try await slot.connection.exec(
                command: command, input: input, environment: environment, retainStdout: retainStdout,
                onStdout: onStdout)
            release(slot, target: target)
            return result
        } catch {
            // A pooled connection that can't open channels is stale (or at
            // the server's session limit): retire it and retry once on a
            // fresh one. (The connection only throws SSHClientError.)
            let stale: Bool
            if case SSHClientError.channelFailed = error { stale = true } else { stale = false }
            if stale { slot.retired = true }
            release(slot, target: target)
            guard stale, reused, !isRetry else { throw error }
            return try await execWithRetry(
                target: target, command: command, input: input, environment: environment,
                retainStdout: retainStdout, onStdout: onStdout, isRetry: true)
        }
    }

    /// Opens an interactive pty session on `target` (see
    /// `SSHTerminalSession`). It occupies one of its connection's channels
    /// until it ends, so a host with many open terminals gets a further
    /// connection for its commands. Throws like `exec`; a session that
    /// fails later ends with `.connectionLost` instead.
    public func openTerminal(
        target: SSHTarget,
        request: SSHTerminalRequest,
        highWaterMark: Int = SSHTerminalSession.defaultHighWaterMark,
        lowWaterMark: Int = SSHTerminalSession.defaultLowWaterMark,
        onOutput: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (SSHTerminalEnd) -> Void
    ) async throws -> SSHTerminalSession {
        try await openTerminal(
            target: target, request: request, highWaterMark: highWaterMark, lowWaterMark: lowWaterMark,
            onOutput: onOutput, onEnd: onEnd, isRetry: false)
    }

    private func openTerminal(
        target: SSHTarget,
        request: SSHTerminalRequest,
        highWaterMark: Int,
        lowWaterMark: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (SSHTerminalEnd) -> Void,
        isRetry: Bool
    ) async throws -> SSHTerminalSession {
        let (slot, reused) = try await acquire(target)
        let session: SSHTerminalSession
        let handedOut = HandOff()
        do {
            session = try await slot.connection.openTerminal(
                request, highWaterMark: highWaterMark, lowWaterMark: lowWaterMark,
                openTimeout: options.channelOpenTimeout,
                startTimeout: options.terminalStartTimeout,
                onOutput: onOutput,
                onEnd: { [weak self] end in
                    // Only the owner of a session hears of its end; one
                    // that ends before it's handed out is told then.
                    if handedOut.ended(end) { onEnd(end) }
                    guard let self else { return }
                    Task { await self.release(slot, target: target) }
                })
        } catch {
            // The connection only throws SSHClientError.channelFailed here.
            let timedOut = (error as? SSHClientError)?.isTimeout ?? false
            if timedOut {
                // A slow server isn't necessarily a dead connection: keep it
                // while others use it, and don't pile on another try. Alone
                // on it, though, let it go — the next open then starts fresh
                // instead of timing out on a server that stopped answering.
                if slot.activeChannels <= 1 { slot.retired = true }
            } else {
                // As for exec: a stale pooled connection gets one retry on a
                // fresh one.
                slot.retired = true
            }
            release(slot, target: target)
            guard !timedOut, reused, !isRetry else { throw error }
            return try await openTerminal(
                target: target, request: request, highWaterMark: highWaterMark, lowWaterMark: lowWaterMark,
                onOutput: onOutput, onEnd: onEnd, isRetry: true)
        }
        // From here the session's end releases the slot. A caller cancelled
        // while it opened won't take ownership of it.
        if Task.isCancelled {
            handedOut.withhold()
            session.close()
            throw CancellationError()
        }
        if let end = handedOut.handOut() { onEnd(end) }
        return session
    }

    /// Whether a session's end goes to its caller: held until the session
    /// is handed out, dropped if it never is.
    private final class HandOff: @unchecked Sendable {
        private enum State { case opening(SSHTerminalEnd?), handedOut, withheld }
        private let lock = NSLock()
        private var state = State.opening(nil)

        /// Whether to deliver `end` now (else it's kept or dropped).
        func ended(_ end: SSHTerminalEnd) -> Bool {
            lock.withLock {
                switch state {
                case .opening: state = .opening(end); return false
                case .handedOut: return true
                case .withheld: return false
                }
            }
        }

        /// Marks the session handed out; returns an end to deliver now.
        func handOut() -> SSHTerminalEnd? {
            lock.withLock {
                guard case .opening(let end) = state else { return nil }
                state = .handedOut
                return end
            }
        }

        func withhold() { lock.withLock { state = .withheld } }
    }

    private func acquire(_ target: SSHTarget) async throws -> (Slot, reused: Bool) {
        var connectedHere = false
        while true {
            try Task.checkCancellation()
            prune(target)
            if let slot = slots[target]?.first(where: {
                !$0.retired && $0.connection.isActive && $0.activeChannels < options.maxChannelsPerConnection
            }) {
                slot.activeChannels += 1
                slot.lastUsed = .now
                return (slot, !connectedHere)
            }
            // A burst of commands shares one handshake: wait for the one in
            // flight (its failure is ours too), then look again. The
            // handshake task registers its connection before finishing, so
            // waking up always finds it.
            if let pending = connecting[target] {
                try await pending.value
                continue
            }
            let task = Task {
                defer { self.connecting[target] = nil }
                let connection = try await self.connect(target)
                self.register(connection, target: target)
            }
            connecting[target] = task
            try await task.value
            connectedHere = true
        }
    }

    private func register(_ connection: SSHConnection, target: SSHTarget) {
        slots[target, default: []].append(Slot(connection: connection))
        connection.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            Task { await self.prune(target) }
        }
    }

    private func release(_ slot: Slot, target: SSHTarget) {
        slot.activeChannels -= 1
        slot.lastUsed = .now
        if slot.activeChannels == 0 {
            if slot.retired {
                slot.connection.close()
            } else {
                let idle = options.idleTimeout
                Task {
                    try? await Task.sleep(for: idle + .seconds(1))
                    self.prune(target)
                }
            }
        }
        prune(target)
    }

    /// Drops closed connections and closes ones idle past the timeout.
    private func prune(_ target: SSHTarget) {
        guard let list = slots[target] else { return }
        let now = ContinuousClock.now
        var kept: [Slot] = []
        for slot in list {
            let idleExpired = slot.activeChannels == 0 && now - slot.lastUsed >= options.idleTimeout
            if !slot.connection.isActive || (slot.activeChannels == 0 && (slot.retired || idleExpired)) {
                slot.connection.close()
            } else {
                kept.append(slot)
            }
        }
        slots[target] = kept.isEmpty ? nil : kept
    }

    /// Open channels on each live connection to `target` (for tests).
    func activeChannels(for target: SSHTarget) -> [Int] {
        (slots[target] ?? []).filter { $0.connection.isActive }.map(\.activeChannels)
    }

    /// Closes every connection (e.g. after host settings change).
    public func closeAll() {
        for slot in slots.values.flatMap({ $0 }) { slot.connection.close() }
        slots = [:]
    }

    /// Signs in to `target` on a connection of its own (never pooled), then
    /// hangs up: proof that its credentials and host key work. Throws like
    /// `exec`.
    public func verifyLogin(target: SSHTarget) async throws {
        let connection = try await connect(target)
        connection.close()
    }

    private func connect(_ target: SSHTarget) async throws -> SSHConnection {
        let offers = Self.authOffers(
            for: target.credentials, agent: options.agent, defaultKeyFiles: options.defaultKeyFiles,
            keyStore: options.keyStore)
        let knownHosts = KnownHosts.load(files: options.knownHostsFiles)
        return try await SSHConnection.connect(
            target: target, offers: offers, knownHosts: knownHosts, group: group,
            connectTimeout: options.connectTimeout, handshakeTimeout: options.handshakeTimeout)
    }

    /// Authentication attempts in OpenSSH's order: the configured key
    /// (agent-held if the agent has it), then the agent's other keys, then
    /// unencrypted key files.
    static func authOffers(
        for credentials: SSHTarget.Credentials,
        agent: SSHAgent?,
        defaultKeyFiles: [String],
        keyStore: (any SSHKeyStore)? = nil
    ) -> [NIOSSHUserAuthenticationOffer.Offer] {
        // Asked only when a key may be offered (not for password auth).
        func agentIdentities() -> [SSHAgent.Identity] { (try? agent?.identities()) ?? [] }
        var offers: [NIOSSHUserAuthenticationOffer.Offer] = []
        var offeredBlobs = Set<Data>()

        func offerAgent(_ identity: SSHAgent.Identity) {
            guard let agent, !offeredBlobs.contains(identity.blob),
                  let key = AgentKeys.privateKey(for: identity, agent: agent) else { return }
            offeredBlobs.insert(identity.blob)
            offers.append(.privateKey(.init(privateKey: key)))
        }
        func offerFile(_ path: String) {
            guard let key = try? OpenSSHKeyFile.load(path: path) else { return }
            var buffer = ByteBufferAllocator().buffer(capacity: 128)
            key.publicKey.write(to: &buffer)
            let blob = Data(buffer.readableBytesView)
            guard !offeredBlobs.contains(blob) else { return }
            offeredBlobs.insert(blob)
            offers.append(.privateKey(.init(privateKey: key)))
        }

        switch credentials {
        case .password(let password):
            return [.password(.init(password: password))]
        case .storedKey(let id):
            guard let key = keyStore?.signingKey(id: id) else { return [] }
            return [.privateKey(.init(privateKey: key))]
        case .keyFile(let path):
            let identities = agentIdentities()
            if let blob = OpenSSHKeyFile.publicKeyBlob(forPrivateKeyAt: path),
               let identity = identities.first(where: { $0.blob == blob }) {
                offerAgent(identity)
            } else {
                offerFile(path)
            }
            identities.forEach(offerAgent)
        case .automatic:
            agentIdentities().forEach(offerAgent)
            defaultKeyFiles.forEach(offerFile)
        }
        return offers
    }
}
