import Foundation
import RelaySSH

/// Runs a terminal's program over SSH: opens a pty session through the
/// pool and wires it to a surface's `ManualTerminalIO` — output in (with
/// flow control: the session reads more only as the terminal consumes),
/// keystrokes and size changes out, and the program's end reported to the
/// surface as a process exit. A connection that can't be opened is
/// reported in the terminal and as exit status 255, as `ssh` would.
public final class SSHTerminalLink: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var target: SSHTarget
        /// nil runs the login shell.
        public var command: String?
        public var term: String
        public var environment: [(String, String)]

        public init(target: SSHTarget, command: String?, term: String = "xterm-256color", environment: [(String, String)] = []) {
            self.target = target
            self.command = command
            self.term = term
            self.environment = environment
        }
    }

    /// The exit status reported for a lost connection or a failure to
    /// connect: what `ssh` exits with.
    public static let connectionFailureStatus: UInt32 = 255

    /// The size used if libghostty hasn't reported one.
    static let fallbackSize = SSHTerminalSize(columns: 80, rows: 24)

    private let io: ManualTerminalIO
    private let pool: SSHConnectionPool
    private let configuration: Configuration
    private let onEnd: (@Sendable (SSHTerminalEnd?, Error?) -> Void)?

    private let lock = NSLock()
    private var session: SSHTerminalSession?
    /// Output consumed before the session object was known.
    private var consumedBeforeSession = 0
    private var openTask: Task<Void, Never>?
    private var closed = false

    /// `onEnd` (optional, for the app's bookkeeping) receives how the
    /// session ended, or the error that kept it from opening.
    public init(
        io: ManualTerminalIO,
        pool: SSHConnectionPool = .shared,
        configuration: Configuration,
        onEnd: (@Sendable (SSHTerminalEnd?, Error?) -> Void)? = nil
    ) {
        self.io = io
        self.pool = pool
        self.configuration = configuration
        self.onEnd = onEnd
    }

    /// Opens the session. Call once, after the surface is attached.
    public func start() {
        lock.withLock {
            guard !closed, openTask == nil else { return }
            openTask = Task { await self.open() }
        }
    }

    /// Ends the session (the terminal is going away). No exit is reported
    /// to the surface.
    public func close() {
        let (session, task) = lock.withLock { () -> (SSHTerminalSession?, Task<Void, Never>?) in
            closed = true
            return (self.session, openTask)
        }
        task?.cancel()
        session?.close()
    }

    private func open() async {
        let requested = io.size ?? Self.fallbackSize
        let request = SSHTerminalRequest(
            term: configuration.term, size: requested,
            command: configuration.command, environment: configuration.environment)
        let io = io
        do {
            let session = try await pool.openTerminal(
                target: configuration.target,
                request: request,
                onOutput: { [weak self] data in
                    guard let self else { return }
                    io.feed(data) { self.consumed(data.count) }
                },
                onEnd: { [weak self] end in
                    // Not for a local close: the surface is going away.
                    if end != .closedLocally {
                        io.reportExit(code: Self.exitStatus(for: end))
                    }
                    self?.onEnd?(end, nil)
                })
            let alreadyConsumed: Int? = lock.withLock {
                guard !closed else { return nil }
                self.session = session
                defer { consumedBeforeSession = 0 }
                return consumedBeforeSession
            }
            guard let alreadyConsumed else {
                session.close()
                return
            }
            if alreadyConsumed > 0 { session.outputConsumed(alreadyConsumed) }
            io.setInputHandler { session.write($0) }
            // Also delivers any size change since the request.
            io.setResizeHandler { session.resize($0) }
        } catch {
            guard !lock.withLock({ closed }) else { return }
            let message = "\r\n[relay] Couldn't open a terminal on \(configuration.target.host): \(Self.describe(error))\r\n"
            io.feed(Data(message.utf8))
            io.reportExit(code: Self.connectionFailureStatus)
            onEnd?(nil, error)
        }
    }

    private func consumed(_ byteCount: Int) {
        let session: SSHTerminalSession? = lock.withLock {
            // A closed link's session reads nothing more.
            if closed { return nil }
            if let session = self.session { return session }
            consumedBeforeSession += byteCount
            return nil
        }
        session?.outputConsumed(byteCount)
    }

    static func exitStatus(for end: SSHTerminalEnd) -> UInt32 {
        switch end {
        case .exited(let code): return UInt32(bitPattern: code) & 0xFF
        case .connectionLost, .closedLocally: return connectionFailureStatus
        }
    }

    public static func describe(_ error: Error) -> String {
        if let clientError = error as? SSHClientError { return clientError.description }
        return String(describing: error)
    }
}
