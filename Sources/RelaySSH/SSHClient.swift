import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// Where and as whom to connect. Hashable so connections can be pooled per
/// target (a changed password or key is a different target).
public struct SSHTarget: Sendable, Hashable {
    public enum Credentials: Sendable, Hashable {
        /// ssh-agent keys, then unencrypted default key files — what
        /// OpenSSH tries with no IdentityFile configured.
        case automatic
        /// That key: via the agent when it holds it, else the file itself
        /// when it isn't passphrase-protected; then other agent keys.
        case keyFile(path: String)
        case password(String)
        /// One of Relay's own keys (`SSHKeyStore`), and nothing else.
        case storedKey(id: String)
    }

    public var host: String
    public var port: Int
    public var username: String
    public var credentials: Credentials

    public init(host: String, port: Int = 22, username: String, credentials: Credentials) {
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
    }
}

/// What a command reads on stdin.
public enum SSHExecInput: Sendable {
    case data(Data)
    /// A local file's contents, streamed as the channel's window allows
    /// (never read into memory whole). `onProgress` gets the running total
    /// of bytes sent.
    case file(URL, onProgress: (@Sendable (Int64) -> Void)?)
}

public struct SSHExecResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
}

public enum SSHClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// DNS, refused, timed out — the host isn't reachable at all.
    case unreachable(String)
    case hostKeyNotTrusted(KnownHosts.Verdict, presented: String)
    case authenticationFailed
    case handshakeFailed(String)
    /// The connection is up but a command channel couldn't be opened or
    /// the exec request was refused.
    case channelFailed(String)
    /// The connection dropped while a command was running.
    case connectionLost

    /// `channelFailed` details for a server that was merely slow (as
    /// opposed to refusing): no reason to give up on the connection.
    static let openTimedOut = "timed out opening a channel"
    static let startTimedOut = "timed out starting the terminal"

    var isTimeout: Bool {
        if case .channelFailed(let detail) = self { return detail == Self.openTimedOut || detail == Self.startTimedOut }
        return false
    }

    public var description: String {
        switch self {
        case .unreachable(let detail): return "unreachable: \(detail)"
        case .hostKeyNotTrusted(let verdict, _): return "host key \(verdict)"
        case .authenticationFailed: return "authentication failed"
        case .handshakeFailed(let detail): return "handshake failed: \(detail)"
        case .channelFailed(let detail): return "channel failed: \(detail)"
        case .connectionLost: return "connection lost"
        }
    }
}

/// One authenticated SSH connection; commands run on their own channels,
/// many at a time.
final class SSHConnection: @unchecked Sendable {
    let target: SSHTarget
    private let channel: Channel

    var isActive: Bool { channel.isActive }
    var closeFuture: EventLoopFuture<Void> { channel.closeFuture }
    var channelEventLoop: EventLoop { channel.eventLoop }

    private init(target: SSHTarget, channel: Channel) {
        self.target = target
        self.channel = channel
    }

    func close() {
        channel.close(promise: nil)
    }

    static func connect(
        target: SSHTarget,
        offers: [NIOSSHUserAuthenticationOffer.Offer],
        knownHosts: KnownHosts,
        group: EventLoopGroup,
        connectTimeout: TimeAmount,
        handshakeTimeout: TimeAmount = .seconds(20)
    ) async throws -> SSHConnection {
        let failure = FailureBox()
        let authenticated = group.next().makePromise(of: Void.self)
        let userAuth = OfferingAuthDelegate(username: target.username, offers: offers, failure: failure)
        let serverAuth = KnownHostsDelegate(host: target.host, port: target.port, knownHosts: knownHosts, failure: failure)

        var bootstrap = ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            // Dead-peer detection (the job ServerAliveInterval does for
            // ssh): a dropped network closes the connection in ~30 s.
            .channelOption(ChannelOptions.socket(SOL_SOCKET, SO_KEEPALIVE), value: 1)
        #if canImport(Darwin)
        bootstrap = bootstrap
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPALIVE), value: 15)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPINTVL), value: 5)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPCNT), value: 3)
        #endif
        bootstrap = bootstrap.channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let sync = channel.pipeline.syncOperations
                try sync.addHandler(NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil))
                try sync.addHandler(HandshakeWatcher(authenticated: authenticated))
            }
        }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: target.host, port: target.port).get()
        } catch {
            authenticated.fail(error)
            throw SSHClientError.unreachable(Self.describeConnectError(error, host: target.host))
        }

        // A server that hangs up before authentication fails the handshake
        // at once (NIOSSHHandler doesn't pass channelInactive on, so the
        // watcher can't see it). After success this is a no-op.
        channel.closeFuture.whenComplete { _ in
            authenticated.fail(SSHClientError.handshakeFailed("connection closed"))
        }
        // Key exchange + auth; bounded so a server that stalls mid-handshake
        // can't hang a caller.
        let handshakeTimer = channel.eventLoop.scheduleTask(in: handshakeTimeout) {
            authenticated.fail(SSHClientError.handshakeFailed("timed out"))
        }
        do {
            try await authenticated.futureResult.get()
            handshakeTimer.cancel()
        } catch {
            handshakeTimer.cancel()
            channel.close(promise: nil)
            if let recorded = failure.value { throw recorded }
            if let clientError = error as? SSHClientError { throw clientError }
            throw SSHClientError.handshakeFailed(String(describing: error))
        }
        return SSHConnection(target: target, channel: channel)
    }

    /// Runs `command` with `stdin` delivered then closed (EOF). Cancelling
    /// the calling task closes the channel.
    func exec(
        command: String,
        input: SSHExecInput,
        environment: [(String, String)],
        retainStdout: Bool = true,
        onStdout: (@Sendable (Data) -> Void)?
    ) async throws -> SSHExecResult {
        let done = channel.eventLoop.makePromise(of: SSHExecResult.self)
        let handler = ExecHandler(
            command: command, input: input, environment: environment, retainStdout: retainStdout,
            onStdout: onStdout, done: done)
        let child: Channel
        do {
            child = try await openChannel(timeout: .seconds(10)) { $0.pipeline.addHandler(handler) }
        } catch {
            done.fail(error)
            throw error
        }
        return try await withTaskCancellationHandler {
            try await done.futureResult.get()
        } onCancel: {
            child.close(promise: nil)
        }
    }

    /// Opens a session channel set up by `initialize`. Throws
    /// `SSHClientError.channelFailed` if the server refuses or doesn't
    /// answer within `timeout`.
    func openChannel(
        timeout: TimeAmount,
        initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let eventLoop = channel.eventLoop
        let opened = eventLoop.makePromise(of: Channel.self)
        let late = LateChannel()
        // Recorded on the loop, so a timer firing just after the channel
        // opened (before this task resumes to cancel it) leaves it alone.
        opened.futureResult.whenSuccess { _ in late.opened = true }
        let openTimeout = eventLoop.scheduleTask(in: timeout) {
            guard !late.opened else { return }
            // The open request can't be withdrawn: a channel the server
            // confirms later would run unowned. Close it, now or when it
            // turns up.
            late.timedOut = true
            late.child?.close(promise: nil)
            opened.fail(SSHClientError.channelFailed(SSHClientError.openTimedOut))
        }
        // NIOSSHHandler is confined to its event loop: look it up there.
        eventLoop.execute { [channel] in
            do {
                let sshHandler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(opened, channelType: .session) { child, _ in
                    late.child = child
                    // Failing setup ends a channel that hasn't been opened
                    // yet (a close would wait for an activation that, with
                    // no open sent, never comes).
                    guard !late.timedOut else {
                        return child.eventLoop.makeFailedFuture(SSHClientError.channelFailed(SSHClientError.openTimedOut))
                    }
                    return initialize(child)
                }
            } catch {
                opened.fail(SSHClientError.channelFailed("connection closed"))
            }
        }
        do {
            let child = try await opened.futureResult.get()
            openTimeout.cancel()
            return child
        } catch {
            openTimeout.cancel()
            if let clientError = error as? SSHClientError { throw clientError }
            throw SSHClientError.channelFailed(String(describing: error))
        }
    }

    static func describeConnectError(_ error: Error, host: String) -> String {
        if let connection = error as? NIOConnectionError {
            if connection.dnsAError != nil || connection.dnsAAAAError != nil, connection.connectionErrors.isEmpty {
                return "Could not resolve hostname \(host)"
            }
            if let first = connection.connectionErrors.first {
                return describeConnectError(first.error, host: host)
            }
        }
        if case ChannelError.connectTimeout = error { return "Operation timed out" }
        if let io = error as? IOError { return String(cString: strerror(io.errnoCode)) }
        return String(describing: error)
    }
}

// MARK: Handlers & delegates

/// A channel being opened, for the open timeout (event-loop confined).
final class LateChannel: @unchecked Sendable {
    var opened = false
    var timedOut = false
    var child: Channel?
}

/// Records the specific reason a handshake failed (NIOSSH surfaces a
/// generic error once a delegate fails its promise).
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: SSHClientError?
    var value: SSHClientError? { lock.withLock { _value } }
    func set(_ error: SSHClientError) { lock.withLock { if _value == nil { _value = error } } }
}

/// Delegates and handlers below live on their connection's event loop.
final class OfferingAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]
    private let failure: FailureBox

    init(username: String, offers: [NIOSSHUserAuthenticationOffer.Offer], failure: FailureBox) {
        self.username = username
        self.offers = offers
        self.failure = failure
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            let usable: Bool
            switch offer {
            case .privateKey: usable = availableMethods.contains(.publicKey)
            case .password: usable = availableMethods.contains(.password)
            default: usable = false
            }
            if usable {
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
                return
            }
        }
        failure.set(.authenticationFailed)
        nextChallengePromise.fail(SSHClientError.authenticationFailed)
    }
}

final class KnownHostsDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let knownHosts: KnownHosts
    private let failure: FailureBox

    init(host: String, port: Int, knownHosts: KnownHosts, failure: FailureBox) {
        self.host = host
        self.port = port
        self.knownHosts = knownHosts
        self.failure = failure
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // NIOSSH renders keys as "<type> <base64 blob>"; anything else
        // (never seen) matches no known_hosts entry and is refused below.
        let line = String(openSSHPublicKey: hostKey)
        let fields = line.split(separator: " ").map(String.init) + ["", ""]
        let verdict = knownHosts.verify(
            host: host, port: port, keyType: fields[0], key: Data(base64Encoded: fields[1]) ?? Data())
        if verdict == .trusted {
            validationCompletePromise.succeed(())
        } else {
            failure.set(.hostKeyNotTrusted(verdict, presented: line))
            validationCompletePromise.fail(SSHClientError.hostKeyNotTrusted(verdict, presented: line))
        }
    }
}

final class HandshakeWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let authenticated: EventLoopPromise<Void>

    init(authenticated: EventLoopPromise<Void>) {
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            authenticated.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        authenticated.fail(error)
        context.close(promise: nil)
    }

}

/// One exec channel: sends env + exec, then stdin and EOF once the exec is
/// accepted (a file streamed as the window opens); collects stdout/stderr
/// and the exit status.
final class ExecHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let input: SSHExecInput
    private let environment: [(String, String)]
    private let retainStdout: Bool
    private let onStdout: (@Sendable (Data) -> Void)?
    private var file: FileHandle?
    private var fileOffset: Int64 = 0
    private var inputDone = false
    static let fileChunkSize = 64 * 1024
    private var done: EventLoopPromise<SSHExecResult>?

    private var stdout = Data()
    private var stderr = Data()
    private var exitCode: Int32?
    private var execAccepted = false
    private var failure: Error?

    convenience init(
        command: String,
        stdin: Data,
        environment: [(String, String)],
        onStdout: (@Sendable (Data) -> Void)?,
        done: EventLoopPromise<SSHExecResult>
    ) {
        self.init(command: command, input: .data(stdin), environment: environment, onStdout: onStdout, done: done)
    }

    init(
        command: String,
        input: SSHExecInput,
        environment: [(String, String)],
        retainStdout: Bool = true,
        onStdout: (@Sendable (Data) -> Void)?,
        done: EventLoopPromise<SSHExecResult>
    ) {
        self.command = command
        self.input = input
        self.environment = environment
        self.retainStdout = retainStdout
        self.onStdout = onStdout
        self.done = done
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // NIOSSH child channels always support the option.
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        for (name, value) in environment {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value), promise: nil)
        }
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            guard !execAccepted else { return }
            execAccepted = true
            switch input {
            case .data(let stdin):
                inputDone = true
                var buffer = context.channel.allocator.buffer(capacity: stdin.count)
                buffer.writeBytes(stdin)
                context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))).whenComplete { _ in
                    context.close(mode: .output, promise: nil)
                }
            case .file(let url, _):
                do {
                    file = try FileHandle(forReadingFrom: url)
                } catch {
                    failure = failure ?? SSHClientError.channelFailed("couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
                    context.close(promise: nil)
                    return
                }
                pumpFile(context: context)
            }
        case is ChannelFailureEvent:
            failure = failure ?? SSHClientError.channelFailed("the server refused the command")
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitCode = Int32(truncatingIfNeeded: status.exitStatus)
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exitCode = 128 + Self.signalNumber(signal.signalName)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    /// Sends file chunks while the channel can take them; resumes when it
    /// becomes writable again; EOF after the last.
    private func pumpFile(context: ChannelHandlerContext) {
        guard !inputDone, let file, case .file(_, let onProgress) = input else { return }
        while context.channel.isWritable {
            let chunk: Data
            do {
                chunk = try file.read(upToCount: Self.fileChunkSize) ?? Data()
            } catch {
                failure = failure ?? SSHClientError.channelFailed("couldn't read the file: \(error.localizedDescription)")
                context.close(promise: nil)
                return
            }
            if chunk.isEmpty {
                inputDone = true
                try? file.close()
                self.file = nil
                context.flush()
                context.close(mode: .output, promise: nil)
                return
            }
            fileOffset += Int64(chunk.count)
            var buffer = context.channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            let sent = fileOffset
            context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))).whenSuccess { _ in
                onProgress?(sent)
            }
        }
        context.flush()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { pumpFile(context: context) }
        context.fireChannelWritabilityChanged()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = Data(buffer.readableBytesView)
        // Other extended streams carry nothing a command's caller wants.
        if message.type == .channel {
            if retainStdout { stdout.append(bytes) }
            onStdout?(bytes)
        } else if message.type == .stdErr {
            stderr.append(bytes)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failure = failure ?? error
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish()
    }

    private func finish() {
        guard let done else { return }
        self.done = nil
        try? file?.close()
        file = nil
        if let exitCode {
            done.succeed(SSHExecResult(exitCode: exitCode, stdout: stdout, stderr: stderr))
        } else if !execAccepted {
            done.fail(failure as? SSHClientError ?? SSHClientError.channelFailed(failure.map { String(describing: $0) } ?? "channel closed"))
        } else {
            done.fail(SSHClientError.connectionLost)
        }
    }

    /// RFC 4254 §6.10 signal names → POSIX numbers (for the 128+n status a
    /// shell would report).
    static func signalNumber(_ name: String) -> Int32 {
        switch name {
        case "HUP": return 1
        case "INT": return 2
        case "QUIT": return 3
        case "ILL": return 4
        case "ABRT": return 6
        case "FPE": return 8
        case "KILL": return 9
        case "SEGV": return 11
        case "PIPE": return 13
        case "ALRM": return 14
        case "TERM": return 15
        default: return 0
        }
    }
}
