import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
@preconcurrency import NIOSSH
import RelayTestSupport
import Testing
@testable import RelaySSH

/// The client's failure paths — which a terminal hits as surely as a
/// command does — against the fake server and misbehaving listeners.
@Suite("SSH client failures", .serialized)
struct SSHClientFailureTests {
    let scratch: URL

    init() throws {
        scratch = try makeScratchDirectory("ssh-fail")
    }

    func options(knownHosts: [String], handshakeTimeout: TimeAmount = .seconds(20)) -> SSHConnectionPool.Options {
        var options = SSHConnectionPool.Options()
        options.knownHostsFiles = knownHosts
        options.agent = nil
        options.defaultKeyFiles = []
        options.handshakeTimeout = handshakeTimeout
        return options
    }

    func pool(for server: FakeSSHServer) throws -> SSHConnectionPool {
        SSHConnectionPool(options: options(knownHosts: [try server.writeKnownHosts(in: scratch)]))
    }

    func exec(_ pool: SSHConnectionPool, _ target: SSHTarget, _ command: String,
              environment: [(String, String)] = [], timeout: Duration = .seconds(10)) async throws -> SSHExecResult {
        try await pool.exec(target: target, command: command, stdin: Data(), environment: environment, timeout: timeout)
    }

    // MARK: Authentication and host keys

    @Test func aWrongPasswordFailsAuthentication() async throws {
        let server = try FakeSSHServer()
        var target = server.target
        target.credentials = .password("not-the-password")
        await #expect(throws: SSHClientError.authenticationFailed) {
            _ = try await exec(try pool(for: server), target, "true")
        }
        // A terminal fails the same way.
        await #expect(throws: SSHClientError.authenticationFailed) {
            _ = try await pool(for: server).openTerminal(
                target: target, request: SSHTerminalRequest(size: SSHTerminalSize(columns: 80, rows: 24)),
                onOutput: { _ in }, onEnd: { _ in })
        }
    }

    @Test func anUnknownHostKeyIsRefused() async throws {
        let server = try FakeSSHServer()
        let empty = scratch.appendingPathComponent("known_hosts_empty")
        try Data().write(to: empty)
        let pool = SSHConnectionPool(options: options(knownHosts: [empty.path]))
        do {
            _ = try await exec(pool, server.target, "true")
            Issue.record("expected the host key to be refused")
        } catch SSHClientError.hostKeyNotTrusted(let verdict, let presented) {
            #expect(verdict == .unknown)
            #expect(presented.hasPrefix("ssh-ed25519 "))
        }
    }

    @Test func aChangedHostKeyIsRefused() async throws {
        let server = try FakeSSHServer()
        let other = try FakeSSHServer()
        // The other server's key, recorded for this one's address.
        let otherKey = other.knownHostsLine.split(separator: " ", maxSplits: 1)[1]
        let file = scratch.appendingPathComponent("known_hosts_changed")
        try "[127.0.0.1]:\(server.port) \(otherKey)\n".write(to: file, atomically: true, encoding: .utf8)
        let pool = SSHConnectionPool(options: options(knownHosts: [file.path]))
        do {
            _ = try await exec(pool, server.target, "true")
            Issue.record("expected the host key to be refused")
        } catch SSHClientError.hostKeyNotTrusted(let verdict, _) {
            #expect(verdict == .changed)
        }
    }

    // MARK: Reaching the host

    @Test func aClosedPortIsUnreachable() async throws {
        let port = try TestSSHD.freePort()
        let target = SSHTarget(host: "127.0.0.1", port: port, username: "u", credentials: .password("p"))
        do {
            _ = try await exec(SSHConnectionPool(options: options(knownHosts: [])), target, "true")
            Issue.record("expected the connection to fail")
        } catch SSHClientError.unreachable(let detail) {
            #expect(detail.lowercased().contains("refused"), "\(detail)")
        }
    }

    @Test func anUnresolvableHostIsUnreachable() async throws {
        let target = SSHTarget(host: "relay-test.invalid", port: 22, username: "u", credentials: .password("p"))
        do {
            _ = try await exec(SSHConnectionPool(options: options(knownHosts: [])), target, "true")
            Issue.record("expected the lookup to fail")
        } catch SSHClientError.unreachable(let detail) {
            #expect(detail == "Could not resolve hostname relay-test.invalid", "\(detail)")
        }
    }

    @Test func aServerThatNeverSpeaksTimesOutTheHandshake() async throws {
        let listener = try SilentListener(closeImmediately: false)
        let target = SSHTarget(host: "127.0.0.1", port: listener.port, username: "u", credentials: .password("p"))
        let pool = SSHConnectionPool(options: options(knownHosts: [], handshakeTimeout: .milliseconds(300)))
        await #expect(throws: SSHClientError.handshakeFailed("timed out")) {
            _ = try await exec(pool, target, "true")
        }
        withExtendedLifetime(listener) {}
    }

    @Test func aServerThatHangsUpFailsTheHandshakeAtOnce() async throws {
        let listener = try SilentListener(closeImmediately: true)
        let target = SSHTarget(host: "127.0.0.1", port: listener.port, username: "u", credentials: .password("p"))
        // Repeatedly: whether the hang-up or our version string goes first,
        // it fails promptly, not after the handshake timeout.
        for _ in 0..<30 {
            let started = ContinuousClock.now
            do {
                _ = try await exec(SSHConnectionPool(options: options(knownHosts: [])), target, "true")
                Issue.record("expected the handshake to fail")
            } catch SSHClientError.handshakeFailed {
            }
            #expect(ContinuousClock.now - started < .seconds(5))
        }
        withExtendedLifetime(listener) {}
    }

    @Test func connectErrorsAreDescribedReadably() {
        #expect(SSHConnection.describeConnectError(ChannelError.connectTimeout(.seconds(1)), host: "h") == "Operation timed out")
        #expect(SSHConnection.describeConnectError(IOError(errnoCode: ECONNREFUSED, reason: "connect"), host: "h")
                == String(cString: strerror(ECONNREFUSED)))
        struct Odd: Error {}
        #expect(SSHConnection.describeConnectError(Odd(), host: "h") == "Odd()")
        #expect(SSHClientError.channelFailed(SSHClientError.openTimedOut).isTimeout)
        #expect(SSHClientError.channelFailed(SSHClientError.startTimedOut).isTimeout)
        #expect(!SSHClientError.channelFailed("refused").isTimeout)
        #expect(!SSHClientError.connectionLost.isTimeout)
    }

    // MARK: Commands and the pool

    @Test func commandsGetTheirEnvironment() async throws {
        let server = try FakeSSHServer()
        let result = try await exec(try pool(for: server), server.target, "echo got=$RELAY_ENV",
                                    environment: [("RELAY_ENV", "value")])
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("got=value"))
    }

    @Test func aSlowCommandTimesOut() async throws {
        let server = try FakeSSHServer()
        await #expect(throws: SSHConnectionPool.ExecError.self) {
            _ = try await exec(try pool(for: server), server.target, "sleep 10", timeout: .milliseconds(300))
        }
    }

    @Test func aCancelledCommandEndsItsProgram() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        let task = Task { try await exec(pool, server.target, "sleep 30") }
        let deadline = ContinuousClock.now + .seconds(10)
        while server.sessions.first?.pid == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(server.sessions.first?.pid)
        task.cancel()
        _ = try? await task.value
        let gone = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < gone { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(pid, 0) != 0)
    }

    @Test func aRefusingConnectionIsRetiredAndRetriedOnce() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        _ = try await exec(pool, server.target, "true")
        #expect(server.connectionCount == 1)
        server.faults.refuseProgram = true
        await #expect(throws: SSHClientError.self) { _ = try await exec(pool, server.target, "true") }
        // The pooled connection was given up and one fresh one tried.
        #expect(server.connectionCount == 2)
        server.faults.refuseProgram = false
        let result = try await exec(pool, server.target, "echo again")
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("again"))
    }

    @Test func concurrentFirstCommandsShareOneHandshake() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for i in 0..<6 { group.addTask { try await exec(pool, server.target, "exit \(i)").exitCode } }
            var codes: [Int32] = []
            for try await code in group { codes.append(code) }
            #expect(codes.sorted() == Array(0..<6))
        }
        #expect(server.connectionCount == 1)
    }

    @Test func closeAllDropsEveryConnection() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        _ = try await exec(pool, server.target, "true")
        #expect(await pool.activeChannels(for: server.target).count == 1)
        await pool.closeAll()
        #expect(await pool.activeChannels(for: server.target).isEmpty)
        _ = try await exec(pool, server.target, "true")
        #expect(server.connectionCount == 2)
    }

    // MARK: Channels on a connection

    func connect(_ server: FakeSSHServer) async throws -> SSHConnection {
        let knownHosts = KnownHosts.load(files: [try server.writeKnownHosts(in: scratch)])
        return try await SSHConnection.connect(
            target: server.target, offers: [.password(.init(password: FakeSSHServer.password))],
            knownHosts: knownHosts, group: MultiThreadedEventLoopGroup.singleton, connectTimeout: .seconds(5))
    }

    @Test func aClosedConnectionOpensNoChannels() async throws {
        let server = try FakeSSHServer()
        let connection = try await connect(server)
        connection.close()
        try await connection.closeFuture.get()
        await #expect(throws: SSHClientError.self) {
            _ = try await connection.openChannel(timeout: .seconds(5)) { $0.eventLoop.makeSucceededVoidFuture() }
        }
    }

    @Test func anImmediateOpenTimeoutLeavesNoChannel() async throws {
        let server = try FakeSSHServer()
        let connection = try await connect(server)
        defer { connection.close() }
        for _ in 0..<20 {
            _ = try? await connection.openChannel(timeout: .nanoseconds(0)) { $0.eventLoop.makeSucceededVoidFuture() }
        }
        // The connection is still usable, and no program was ever started.
        let child = try await connection.openChannel(timeout: .seconds(5)) { $0.eventLoop.makeSucceededVoidFuture() }
        child.close(promise: nil)
        #expect(server.sessions.allSatisfy { $0.pid == nil })
    }
}

/// Terminal channel handler edge cases, driven directly.
@Suite("Terminal channel handler")
struct TerminalChannelHandlerTests {
    final class Recorder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = Any
        var events: [Any] = []
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) { events.append(event) }
    }

    struct Unrelated: Hashable {}

    @Test func ignoresWhatItDoesNotHandleAndPassesOnUnknownEvents() throws {
        let channel = EmbeddedChannel()
        let started = channel.eventLoop.makePromise(of: Void.self)
        let output = ByteBox()
        let handler = TerminalChannelHandler(
            request: SSHTerminalRequest(size: SSHTerminalSize(columns: 80, rows: 24)),
            highWaterMark: 1 << 20, lowWaterMark: 1 << 18,
            onOutput: { data in output.append(data) }, onEnd: { _ in }, started: started)
        let recorder = Recorder()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.pipeline.syncOperations.addHandler(recorder)
        channel.pipeline.fireChannelActive()

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        try started.futureResult.wait()
        // A stray reply once running changes nothing.
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        // Events it doesn't consume continue down the pipeline.
        channel.pipeline.fireUserInboundEventTriggered(Unrelated())
        #expect(recorder.events.contains { $0 is Unrelated })
        #expect(!recorder.events.contains { $0 is ChannelSuccessEvent })

        // Output on an extended stream other than stderr isn't terminal output.
        var buffer = channel.allocator.buffer(capacity: 4)
        buffer.writeString("odd!")
        channel.pipeline.fireChannelRead(NIOAny(SSHChannelData(type: .init(extended: 7), data: .byteBuffer(buffer))))
        buffer.clear()
        buffer.writeString("real")
        channel.pipeline.fireChannelRead(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))))
        #expect(output.data == Data("real".utf8))
        _ = try? channel.finish()
    }
}

final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    func append(_ data: Data) { lock.withLock { _data.append(data) } }
    var data: Data { lock.withLock { _data } }
}

/// Accepts TCP connections and either says nothing or hangs up at once.
final class SilentListener: @unchecked Sendable {
    let port: Int
    private let channel: Channel

    init(closeImmediately: Bool) throws {
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                if closeImmediately { return child.close() }
                return child.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        port = channel.localAddress!.port!
    }

    deinit {
        channel.close(promise: nil)
    }
}
