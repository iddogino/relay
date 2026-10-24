import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// A terminal's size in cells and pixels, as sent in pty-req and
/// window-change requests.
public struct SSHTerminalSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int
    public var widthPx: Int
    public var heightPx: Int

    public init(columns: Int, rows: Int, widthPx: Int = 0, heightPx: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// What to run on a remote pty.
public struct SSHTerminalRequest: Sendable {
    public var term: String
    public var size: SSHTerminalSize
    /// Run this command (as `ssh -t host command` would); nil starts the
    /// user's login shell.
    public var command: String?
    /// Sent as env requests; the server accepts only what its AcceptEnv
    /// allows, so these are best-effort.
    public var environment: [(String, String)]

    public init(term: String = "xterm-256color", size: SSHTerminalSize, command: String? = nil, environment: [(String, String)] = []) {
        self.term = term
        self.size = size
        self.command = command
        self.environment = environment
    }
}

/// How a terminal session ended.
public enum SSHTerminalEnd: Sendable, Hashable {
    /// The remote program exited (a signal death is 128 + n, as a shell
    /// reports it).
    case exited(Int32)
    /// The channel closed without an exit status: the connection dropped,
    /// or the server ended the session.
    case connectionLost
    /// `close()` was called.
    case closedLocally
}

/// An interactive session on a remote pty. Output arrives through the
/// `onOutput` handler given when it was opened, in order, on an internal
/// thread; the consumer reports what it has processed with
/// `outputConsumed(_:)`. Once more than `highWaterMark` bytes are
/// unconsumed the session stops reading, the server's flow-control window
/// fills, and the remote program blocks — the backpressure a local pty
/// would apply. `onEnd` is called exactly once, after the last output.
///
/// `write`, `resize`, `outputConsumed`, and `close` are safe from any
/// thread; writes are sent in the order they're made.
public final class SSHTerminalSession: @unchecked Sendable {
    public static let defaultHighWaterMark = 1 << 20
    public static let defaultLowWaterMark = 1 << 18

    private let channel: Channel
    private let handler: TerminalChannelHandler

    init(channel: Channel, handler: TerminalChannelHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Sends input to the remote program.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    /// Tells the remote pty its new size (a window-change request).
    public func resize(_ size: SSHTerminalSize) {
        let handler = handler
        channel.eventLoop.execute { handler.resize(size) }
    }

    /// Reports that `byteCount` bytes of delivered output have been
    /// processed, letting reading resume once below the low-water mark.
    public func outputConsumed(_ byteCount: Int) {
        let handler = handler
        channel.eventLoop.execute { handler.consumed(byteCount) }
    }

    /// Closes the channel (like closing a terminal window: the remote side
    /// sees a hangup). `onEnd` follows with `.closedLocally` unless the
    /// session had already ended.
    public func close() {
        let handler = handler
        let channel = channel
        channel.eventLoop.execute {
            handler.closeRequested = true
            channel.close(promise: nil)
        }
    }

    /// Unconsumed output bytes (for tests and diagnostics).
    func unconsumedBytes() async throws -> Int {
        let handler = handler
        return try await channel.eventLoop.submit { handler.inFlight }.get()
    }
}

extension SSHConnection {
    /// Opens a pty channel and starts `request`'s command or shell on it.
    /// Returns once the server has accepted both; throws
    /// `SSHClientError.channelFailed` if it refuses either.
    func openTerminal(
        _ request: SSHTerminalRequest,
        highWaterMark: Int = SSHTerminalSession.defaultHighWaterMark,
        lowWaterMark: Int = SSHTerminalSession.defaultLowWaterMark,
        openTimeout: TimeAmount = .seconds(10),
        startTimeout: TimeAmount = .seconds(15),
        onOutput: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (SSHTerminalEnd) -> Void
    ) async throws -> SSHTerminalSession {
        let eventLoop = channelEventLoop
        let started = eventLoop.makePromise(of: Void.self)
        let handler = TerminalChannelHandler(
            request: request, highWaterMark: highWaterMark, lowWaterMark: lowWaterMark,
            onOutput: onOutput, onEnd: onEnd, started: started)
        let child: Channel
        do {
            child = try await openChannel(timeout: openTimeout) { child in
                child.pipeline.addHandler(handler)
            }
        } catch {
            started.fail(error)
            throw error
        }
        // Bounded so a server that never answers can't hang the caller. The
        // handler is aborted on its loop, so a reply racing the timeout
        // can't start a session nobody owns.
        let startTimer = eventLoop.scheduleTask(in: startTimeout) {
            handler.abortStart(SSHClientError.channelFailed(SSHClientError.startTimedOut))
        }
        do {
            try await started.futureResult.get()
            startTimer.cancel()
        } catch {
            startTimer.cancel()
            child.close(promise: nil)
            // `started` only fails with an SSHClientError.
            throw error
        }
        return SSHTerminalSession(channel: child, handler: handler)
    }
}

/// One pty channel: requests the pty, sends the environment, starts the
/// shell or command, then relays data both ways. Confined to its channel's
/// event loop.
final class TerminalChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let request: SSHTerminalRequest
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private let onOutput: @Sendable (Data) -> Void
    private var onEnd: (@Sendable (SSHTerminalEnd) -> Void)?
    private var started: EventLoopPromise<Void>?

    private enum Phase { case requestingPTY, startingProgram, running, aborted }
    private var phase = Phase.requestingPTY
    private var context: ChannelHandlerContext?
    private var lastSize: SSHTerminalSize
    private var exitCode: Int32?
    fileprivate(set) var inFlight = 0
    private var readHeld = false
    var closeRequested = false {
        didSet { if closeRequested { closing = true } }
    }
    /// Once the channel is closing, nothing more is read: data the server
    /// sent before seeing our close stays undelivered (NIOSSH delivers it
    /// on close anyway), and a read on a locally closed channel would make
    /// NIOSSH send a window adjust its state machine forbids.
    private var closing = false

    init(
        request: SSHTerminalRequest,
        highWaterMark: Int,
        lowWaterMark: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (SSHTerminalEnd) -> Void,
        started: EventLoopPromise<Void>
    ) {
        self.request = request
        self.highWaterMark = highWaterMark
        self.lowWaterMark = min(lowWaterMark, highWaterMark)
        self.onOutput = onOutput
        self.onEnd = onEnd
        self.started = started
        self.lastSize = request.size
    }

    /// Modes the client's tty would contribute (OpenSSH sends its local
    /// tty's): DEL as erase, which is what the terminal sends for
    /// backspace, and IUTF8 so the remote line discipline edits UTF-8
    /// characters as units.
    static let terminalModes = SSHTerminalModes([
        .VERASE: 0x7F,
        SSHTerminalModes.Opcode(rawValue: 42): 1, // IUTF8 (RFC 8160)
    ])

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // The server sends EOF before its exit status; keep the channel
        // open until it closes it so the status isn't lost. (NIOSSH child
        // channels always support the option.)
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish()
        self.context = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        let size = request.size
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: request.term,
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: size.widthPx,
            terminalPixelHeight: size.heightPx,
            terminalModes: Self.terminalModes), promise: nil)
        for (name, value) in request.environment {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value), promise: nil)
        }
        if let command = request.command {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        // Replies arrive in request order: the pty's, then the program's.
        case is ChannelSuccessEvent:
            switch phase {
            case .requestingPTY:
                phase = .startingProgram
            case .startingProgram:
                phase = .running
                started?.succeed(())
                started = nil
            case .running, .aborted:
                break
            }
        case is ChannelFailureEvent:
            let detail = phase == .requestingPTY
                ? "the server refused a terminal"
                : "the server refused to start the \(request.command == nil ? "shell" : "command")"
            started?.fail(SSHClientError.channelFailed(detail))
            started = nil
            closing = true
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitCode = Int32(truncatingIfNeeded: status.exitStatus)
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exitCode = 128 + ExecHandler.signalNumber(signal.signalName)
        case ChannelEvent.inputClosed:
            // Remote EOF; the close (with the exit status before it)
            // follows.
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data, buffer.readableBytes > 0 else { return }
        // A pty merges stderr into stdout; a server that sends extended
        // data anyway still means it for the screen.
        switch message.type {
        case .channel, .stdErr:
            inFlight += buffer.readableBytes
            onOutput(Data(buffer.readableBytesView))
        default:
            break
        }
    }

    /// Holds reads while too much output is unconsumed: unread data stays
    /// in NIOSSH's buffer, so the channel window isn't replenished and the
    /// server stops sending.
    func read(context: ChannelHandlerContext) {
        if inFlight >= highWaterMark || closing {
            readHeld = true
        } else {
            context.read()
        }
    }

    func consumed(_ byteCount: Int) {
        inFlight = max(0, inFlight - byteCount)
        if readHeld, !closing, inFlight <= lowWaterMark, let context {
            readHeld = false
            context.read()
        }
    }

    /// Gives up on starting: the opener gets `error` and the channel closes.
    func abortStart(_ error: Error) {
        guard phase != .running, phase != .aborted else { return }
        phase = .aborted
        started?.fail(error)
        started = nil
        closing = true
        context?.close(promise: nil)
    }

    func resize(_ size: SSHTerminalSize) {
        guard size != lastSize, let context else { return }
        lastSize = size
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: size.widthPx,
            terminalPixelHeight: size.heightPx), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        started?.fail(SSHClientError.channelFailed(String(describing: error)))
        started = nil
        closing = true
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    private func finish() {
        started?.fail(SSHClientError.channelFailed("channel closed"))
        started = nil
        guard let onEnd else { return }
        self.onEnd = nil
        // A session that never started was never handed out: its opener
        // gets the error instead.
        guard phase == .running else { return }
        // A local close wins: sshd answers it with the hangup's exit
        // signal, which isn't the program ending on its own.
        if closeRequested {
            onEnd(.closedLocally)
        } else if let exitCode {
            onEnd(.exited(exitCode))
        } else {
            onEnd(.connectionLost)
        }
    }
}
