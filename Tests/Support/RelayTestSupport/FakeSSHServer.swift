import Crypto
import Darwin
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import RelaySSH

/// An in-process SSH server for tests. Each session runs a real process on
/// a real pty (a shell, or `/bin/sh -c command`), so programs see a genuine
/// terminal: its size, SIGWINCH on window-change, job-control signals,
/// line discipline. Faults can be injected to exercise the client's
/// failure paths. Accepts one password, `FakeSSHServer.password`.
public final class FakeSSHServer: @unchecked Sendable {
    public static let password = "relay-test-password"

    public struct Faults: Sendable {
        public var refusePTY = false
        public var refuseProgram = false
        /// Never answer the pty request (the client must time out).
        public var ignoreRequests = false
        /// End sessions without an exit status.
        public var omitExitStatus = false
        /// Abruptly close the whole connection once this many output bytes
        /// have been sent on a session.
        public var dropConnectionAfterBytes: Int?

        public init() {}
    }

    /// What a session asked for and saw, for assertions.
    public struct SessionRecord: Sendable {
        public var term: String?
        public var initialSize: SSHTerminalSize?
        public var sizes: [SSHTerminalSize] = []
        public var environment: [String: String] = [:]
        public var command: String?
        public var startedShell = false
        public var pid: pid_t?
        /// Output bytes sent to the client so far.
        public var outputBytes = 0
    }

    public let port: Int
    public let knownHostsLine: String
    private let group: MultiThreadedEventLoopGroup
    private let serverChannel: Channel
    private let state: State

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var faults: Faults
        var records: [SessionRecord] = []
        var connections: [Channel] = []
        let shell: [String]
        let baseEnvironment: [String: String]

        init(faults: Faults, shell: [String], baseEnvironment: [String: String]) {
            self.faults = faults
            self.shell = shell
            self.baseEnvironment = baseEnvironment
        }
    }

    /// Starts a server on a free loopback port.
    public init(
        faults: Faults = Faults(),
        shell: [String] = ["/bin/sh"],
        environment: [String: String] = [:]
    ) throws {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var base = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        base.merge(environment) { $1 }
        let state = State(faults: faults, shell: shell, baseEnvironment: base)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                state.lock.withLock { state.connections.append(channel) }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: PasswordDelegate())),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, _ in
                            child.pipeline.addHandler(FakeSessionHandler(state: state, connection: channel))
                        }))
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        self.group = group
        self.serverChannel = channel
        self.state = state
        self.port = channel.localAddress!.port!
        let key = String(openSSHPublicKey: hostKey.publicKey)
        self.knownHostsLine = "[127.0.0.1]:\(port) \(key)"
    }

    public var faults: Faults {
        get { state.lock.withLock { state.faults } }
        set { state.lock.withLock { state.faults = newValue } }
    }

    public var sessions: [SessionRecord] { state.lock.withLock { state.records } }

    /// Client connections accepted so far.
    public var connectionCount: Int { state.lock.withLock { state.connections.count } }

    /// A client target for this server.
    public var target: SSHTarget {
        SSHTarget(host: "127.0.0.1", port: port, username: NSUserName(), credentials: .password(Self.password))
    }

    /// Writes a known_hosts file trusting this server and returns its path.
    public func writeKnownHosts(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("known_hosts_fake_\(port)")
        try (knownHostsLine + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Closes every client connection abruptly (as a network drop would).
    public func dropAllConnections() {
        let connections = state.lock.withLock { state.connections }
        for connection in connections { connection.close(promise: nil) }
    }

    public func shutdown() {
        dropAllConnections()
        try? serverChannel.close().wait()
        try? group.syncShutdownGracefully()
    }

    deinit {
        shutdown()
    }
}

private final class PasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        if case .password(let password) = request.request, password.password == FakeSSHServer.password {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

/// One session channel on the fake server: pty, environment, program, and
/// the byte relay between the channel and the pty master.
private final class FakeSessionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData

    private let state: FakeSSHServer.State
    private let connection: Channel
    private var recordIndex: Int
    private var context: ChannelHandlerContext?

    private var ptySize = SSHTerminalSize(columns: 80, rows: 24)
    private var term = "dumb"
    private var hasPTY = false
    private var environment: [String: String] = [:]
    private var process: PTYProcess?
    private var master: Int32 = -1
    private var masterChannel: Channel?
    private var outputSent = 0
    private var exited: PTYProcess.Termination?
    private var outputDrained = false
    private var finished = false
    private var pendingInput: [ByteBuffer] = []

    init(state: FakeSSHServer.State, connection: Channel) {
        self.state = state
        self.connection = connection
        self.recordIndex = state.lock.withLock {
            state.records.append(FakeSSHServer.SessionRecord())
            return state.records.count - 1
        }
    }

    private var faults: FakeSSHServer.Faults { state.lock.withLock { state.faults } }

    private func record(_ update: (inout FakeSSHServer.SessionRecord) -> Void) {
        state.lock.withLock { update(&state.records[recordIndex]) }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        let faults = faults
        switch event {
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            if faults.ignoreRequests { return }
            let size = SSHTerminalSize(
                columns: request.terminalCharacterWidth, rows: request.terminalRowHeight,
                widthPx: request.terminalPixelWidth, heightPx: request.terminalPixelHeight)
            record {
                $0.term = request.term
                $0.initialSize = size
            }
            if faults.refusePTY {
                reply(context, request.wantReply, success: false)
                return
            }
            ptySize = size
            term = request.term
            hasPTY = true
            reply(context, request.wantReply, success: true)

        case let request as SSHChannelRequestEvent.EnvironmentRequest:
            environment[request.name] = request.value
            record { $0.environment[request.name] = request.value }

        case let request as SSHChannelRequestEvent.ShellRequest:
            record { $0.startedShell = true }
            start(context, argv: state.shell, wantReply: request.wantReply, refuse: faults.refuseProgram)

        case let request as SSHChannelRequestEvent.ExecRequest:
            record { $0.command = request.command }
            start(context, argv: ["/bin/sh", "-c", request.command], wantReply: request.wantReply, refuse: faults.refuseProgram)

        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            let size = SSHTerminalSize(
                columns: request.terminalCharacterWidth, rows: request.terminalRowHeight,
                widthPx: request.terminalPixelWidth, heightPx: request.terminalPixelHeight)
            record { $0.sizes.append(size) }
            ptySize = size
            if master >= 0 {
                PTYProcess.resize(master: master, columns: size.columns, rows: size.rows,
                                  widthPx: size.widthPx, heightPx: size.heightPx)
            }

        case ChannelEvent.inputClosed:
            // Client EOF: like OpenSSH, send ^D to the pty.
            writeToPTY(context.channel.allocator.buffer(bytes: [4]))

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func reply(_ context: ChannelHandlerContext, _ wantReply: Bool, success: Bool) {
        guard wantReply else { return }
        if success {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        } else {
            context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
        }
    }

    private func start(_ context: ChannelHandlerContext, argv: [String], wantReply: Bool, refuse: Bool) {
        // Commands without a pty (the pool's exec channels) get one too;
        // only their output and exit status matter to those callers.
        guard !refuse, process == nil else {
            reply(context, wantReply, success: false)
            return
        }
        var env = state.baseEnvironment
        env.merge(environment) { $1 }
        env["TERM"] = term
        let spawned: PTYProcess
        do {
            spawned = try PTYProcess.spawn(argv, environment: env, columns: ptySize.columns, rows: ptySize.rows,
                                           widthPx: ptySize.widthPx, heightPx: ptySize.heightPx)
        } catch {
            reply(context, wantReply, success: false)
            return
        }
        process = spawned
        record { $0.pid = spawned.pid }
        master = spawned.takeMaster()
        // NIO takes ownership of a duplicate; `master` stays ours for
        // resizing until the session finishes.
        let relayFD = dup(master)
        reply(context, wantReply, success: true)

        let loop = context.eventLoop
        spawned.onExit { [self] termination in
            loop.execute { self.processExited(termination) }
        }
        let relay = MasterRelay(session: self)
        NIOPipeBootstrap(group: loop)
            .channelOption(ChannelOptions.autoRead, value: true)
            .channelInitializer { $0.pipeline.addHandler(relay) }
            .takingOwnershipOfDescriptor(inputOutput: relayFD)
            .whenComplete { [self] result in
                switch result {
                case .success(let channel):
                    masterChannel = channel
                    for buffer in pendingInput { channel.writeAndFlush(buffer, promise: nil) }
                    pendingInput = []
                case .failure:
                    Darwin.close(relayFD)
                    outputDrained = true
                    finishIfDone()
                }
            }
    }

    // MARK: Relay

    /// Output from the program, to the client.
    fileprivate func ptyOutput(_ buffer: ByteBuffer) {
        guard let context, !finished else { return }
        outputSent += buffer.readableBytes
        let sent = outputSent
        record { $0.outputBytes = sent }
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        if let limit = faults.dropConnectionAfterBytes, outputSent >= limit {
            connection.close(promise: nil)
        }
    }

    fileprivate var clientWritable: Bool { context?.channel.isWritable ?? false }

    fileprivate func ptyClosed() {
        outputDrained = true
        finishIfDone()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { masterChannel?.read() }
        context.fireChannelWritabilityChanged()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let buffer) = message.data else { return }
        writeToPTY(buffer)
    }

    private func writeToPTY(_ buffer: ByteBuffer) {
        if let masterChannel {
            masterChannel.writeAndFlush(buffer, promise: nil)
        } else {
            pendingInput.append(buffer)
        }
    }

    private func processExited(_ termination: PTYProcess.Termination) {
        exited = termination
        // Output still buffered in the pty is drained before the status;
        // if something else keeps the pty open, give up after a moment.
        context?.eventLoop.scheduleTask(in: .milliseconds(500)) { [self] in
            outputDrained = true
            finishIfDone()
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard !finished, let exited, outputDrained, let context else { return }
        finished = true
        if !faults.omitExitStatus {
            switch exited {
            case .exited(let code):
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: Int(code)), promise: nil)
            case .signaled(let signal):
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitSignal(
                    signalName: Self.signalName(signal), errorMessage: "", language: "", dumpedCore: false), promise: nil)
            }
        }
        context.close(mode: .output, promise: nil)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        teardown()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        teardown()
        self.context = nil
    }

    /// The client hung up (or the session finished): end the program as a
    /// pty hangup would and release the pty.
    private func teardown() {
        if let process, exited == nil {
            // The program leads its own session and process group.
            kill(-process.pid, SIGHUP)
        }
        masterChannel?.close(promise: nil)
        masterChannel = nil
        if master >= 0 {
            Darwin.close(master)
            master = -1
        }
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP: return "HUP"
        case SIGINT: return "INT"
        case SIGQUIT: return "QUIT"
        case SIGKILL: return "KILL"
        case SIGTERM: return "TERM"
        case SIGSEGV: return "SEGV"
        case SIGPIPE: return "PIPE"
        default: return "USR1"
        }
    }
}

/// Reads the pty master for a session, only while the client can take
/// more (the flow control sshd applies).
private final class MasterRelay: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let session: FakeSessionHandler

    init(session: FakeSessionHandler) {
        self.session = session
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        session.ptyOutput(unwrapInboundIn(data))
    }

    func read(context: ChannelHandlerContext) {
        // Resumed from channelWritabilityChanged.
        if session.clientWritable { context.read() }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // EIO once the program's side of the pty is closed.
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        session.ptyClosed()
        context.fireChannelInactive()
    }
}
