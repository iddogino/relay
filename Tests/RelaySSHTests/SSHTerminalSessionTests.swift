import CryptoKit
import Darwin
import Foundation
import NIOCore
import RelayTestSupport
import Testing
@testable import RelaySSH

/// Interactive pty sessions against the in-process fake server: real
/// processes on real ptys, plus injected faults.
@Suite("SSH terminal sessions (fake server)", .serialized)
struct SSHTerminalSessionFakeServerTests {
    let scratch: URL

    init() throws {
        scratch = try makeScratchDirectory("ssh-term")
    }

    func pool(for server: FakeSSHServer, startTimeout: TimeAmount = .seconds(15), openTimeout: TimeAmount = .seconds(10)) throws -> SSHConnectionPool {
        var options = SSHConnectionPool.Options()
        options.knownHostsFiles = [try server.writeKnownHosts(in: scratch)]
        options.agent = nil
        options.defaultKeyFiles = []
        options.terminalStartTimeout = startTimeout
        options.channelOpenTimeout = openTimeout
        return SSHConnectionPool(options: options)
    }

    @discardableResult
    func open(
        _ pool: SSHConnectionPool,
        _ server: FakeSSHServer,
        command: String?,
        size: SSHTerminalSize = SSHTerminalSize(columns: 80, rows: 24),
        environment: [(String, String)] = [],
        transcript: TerminalTranscript,
        highWaterMark: Int = SSHTerminalSession.defaultHighWaterMark,
        lowWaterMark: Int = SSHTerminalSession.defaultLowWaterMark
    ) async throws -> SSHTerminalSession {
        let session = try await pool.openTerminal(
            target: server.target,
            request: SSHTerminalRequest(size: size, command: command, environment: environment),
            highWaterMark: highWaterMark, lowWaterMark: lowWaterMark,
            onOutput: transcript.onOutput, onEnd: transcript.onEnd)
        transcript.attach(session)
        return session
    }

    // MARK: Program, pty, and exit

    @Test func runsTheCommandOnAPTYOfTheRequestedSize() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        let transcript = TerminalTranscript()
        try await open(pool, server, command: "stty size; tty; echo TERM=$TERM",
                       size: SSHTerminalSize(columns: 132, rows: 43, widthPx: 1320, heightPx: 860), transcript: transcript)
        #expect(try await transcript.waitForEnd() == .exited(0))
        #expect(transcript.text.contains("43 132"))
        #expect(transcript.text.contains("/dev/tty"))
        #expect(transcript.text.contains("TERM=xterm-256color"))
        let record = try #require(server.sessions.first)
        #expect(record.term == "xterm-256color")
        #expect(record.initialSize == SSHTerminalSize(columns: 132, rows: 43, widthPx: 1320, heightPx: 860))
        #expect(transcript.endCallCount == 1)
    }

    @Test(arguments: [0, 1, 42, 255])
    func reportsTheExitStatus(code: Int32) async throws {
        let server = try FakeSSHServer()
        let transcript = TerminalTranscript()
        try await open(try pool(for: server), server, command: "exit \(code)", transcript: transcript)
        #expect(try await transcript.waitForEnd() == .exited(code))
    }

    @Test func reportsASignalDeathAs128PlusTheSignal() async throws {
        let server = try FakeSSHServer()
        let transcript = TerminalTranscript()
        try await open(try pool(for: server), server, command: "kill -TERM $$", transcript: transcript)
        #expect(try await transcript.waitForEnd() == .exited(128 + 15))
    }

    @Test func drivesAnInteractiveShell() async throws {
        let server = try FakeSSHServer(shell: ["/bin/sh", "-i"], environment: ["PS1": "fake$ "])
        let transcript = TerminalTranscript()
        let session = try await open(try pool(for: server), server, command: nil, transcript: transcript)
        try await transcript.waitFor("fake$ ")
        session.write(Data("echo answer-$((6*7))\r".utf8))
        try await transcript.waitFor("answer-42")
        session.write(Data("exit 7\r".utf8))
        #expect(try await transcript.waitForEnd() == .exited(7))
        #expect(server.sessions.first?.startedShell == true)
    }

    @Test func forwardsTheEnvironment() async throws {
        let server = try FakeSSHServer()
        let transcript = TerminalTranscript()
        try await open(try pool(for: server), server, command: "echo got=$RELAY_PROBE",
                       environment: [("RELAY_PROBE", "hello world")], transcript: transcript)
        _ = try await transcript.waitForEnd()
        #expect(transcript.text.contains("got=hello world"))
    }

    // MARK: Window size

    @Test func windowChangesReachTheProgramAsSIGWINCH() async throws {
        let server = try FakeSSHServer()
        let transcript = TerminalTranscript()
        let session = try await open(
            try pool(for: server), server,
            command: "trap 'echo winch $(stty size)' WINCH; echo ready; while :; do sleep 0.02; done",
            transcript: transcript)
        try await transcript.waitFor("ready")
        session.resize(SSHTerminalSize(columns: 120, rows: 40, widthPx: 1200, heightPx: 800))
        try await transcript.waitFor("winch 40 120")
        // An unchanged size isn't sent again.
        session.resize(SSHTerminalSize(columns: 120, rows: 40, widthPx: 1200, heightPx: 800))
        session.resize(SSHTerminalSize(columns: 90, rows: 20, widthPx: 900, heightPx: 400))
        try await transcript.waitFor("winch 20 90")
        #expect(server.sessions.first?.sizes == [
            SSHTerminalSize(columns: 120, rows: 40, widthPx: 1200, heightPx: 800),
            SSHTerminalSize(columns: 90, rows: 20, widthPx: 900, heightPx: 400),
        ])
        session.close()
        #expect(try await transcript.waitForEnd() == .closedLocally)
    }

    // MARK: Data integrity

    @Test func inputIsDeliveredByteExact() async throws {
        let server = try FakeSSHServer()
        let transcript = TerminalTranscript()
        // Raw mode: no echo, no signal keys, no newline translation.
        let session = try await open(
            try pool(for: server), server,
            command: "stty raw -echo; echo ready; head -c 256 | od -An -v -tx1 | tr -d ' \\n'; echo; echo done",
            transcript: transcript)
        try await transcript.waitFor("ready")
        session.write(Data((0...255).map { UInt8($0) }))
        try await transcript.waitFor("done")
        let expected = (0...255).map { String(format: "%02x", $0) }.joined()
        #expect(transcript.text.contains(expected))
    }

    @Test func largeOutputArrivesIntactInOrder() async throws {
        let server = try FakeSSHServer()
        let file = scratch.appendingPathComponent("blob")
        let blob = try writeRandomFile(at: file, count: 8 << 20)
        let transcript = TerminalTranscript()
        // Raw mode keeps the pty from translating the bytes.
        try await open(try pool(for: server), server,
                       command: "stty raw -echo; cat '\(file.path)'", transcript: transcript)
        #expect(try await transcript.waitForEnd(timeout: .seconds(60)) == .exited(0))
        #expect(transcript.output.count == blob.count)
        #expect(transcript.output == blob)
    }

    @Test func fullSizePacketsFromTheServerArrive() async throws {
        // Servers may fill each packet to the size the client announced (Go's
        // x/crypto/ssh does; another NIOSSH does): the client must accept
        // what it announced, headers and padding included.
        let server = try FakeSSHServer()
        var faults = FakeSSHServer.Faults()
        faults.coalesceOutput = 1 << 20
        server.faults = faults
        let file = scratch.appendingPathComponent("packets")
        let blob = try writeRandomFile(at: file, count: 3 << 20)
        let transcript = TerminalTranscript()
        try await open(try pool(for: server), server, command: "stty raw -echo; cat '\(file.path)'", transcript: transcript)
        #expect(try await transcript.waitForEnd(timeout: .seconds(60)) == .exited(0))
        #expect(transcript.output == blob)
    }

    @Test func aLargeWriteReachesTheProgramWhole() async throws {
        // One write far larger than a packet (a big paste): it's split to
        // what the server accepts.
        let server = try FakeSSHServer()
        let input = Data((0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let transcript = TerminalTranscript()
        let session = try await open(
            try pool(for: server), server,
            command: "stty raw -echo; echo ready; head -c \(input.count) | shasum -a 256; echo done",
            transcript: transcript)
        try await transcript.waitFor("ready")
        session.write(input)
        try await transcript.waitFor("done", timeout: .seconds(60))
        #expect(transcript.text.contains(SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()))
    }

    // MARK: Flow control

    @Test func unconsumedOutputStopsTheRemoteProgram() async throws {
        let server = try FakeSSHServer()
        let file = scratch.appendingPathComponent("flood")
        let blob = try writeRandomFile(at: file, count: 16 << 20)
        let transcript = TerminalTranscript(autoConsume: false)
        let highWater = 64 * 1024
        let session = try await open(try pool(for: server), server,
                                     command: "stty raw -echo; cat '\(file.path)'",
                                     transcript: transcript, highWaterMark: highWater, lowWaterMark: 16 * 1024)
        try await transcript.waitUntil("some output") { $0.receivedBytes > 0 }
        try await Task.sleep(for: .milliseconds(500))
        // Bounded by the high-water mark plus one SSH window (128 KiB).
        let held = try await session.unconsumedBytes()
        #expect(held <= highWater + (128 << 10) + 64 << 10)
        #expect(transcript.receivedBytes < 1 << 20)
        // And the server really is stalled, not just buffering for us.
        let sentBefore = server.sessions[0].outputBytes
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.sessions[0].outputBytes == sentBefore)
        #expect(sentBefore < 2 << 20)

        transcript.setAutoConsume(true)
        #expect(try await transcript.waitForEnd(timeout: .seconds(60)) == .exited(0))
        #expect(transcript.output == blob)
    }

    // MARK: Failures

    @Test func aRefusedPTYFailsTheOpen() async throws {
        var faults = FakeSSHServer.Faults()
        faults.refusePTY = true
        let server = try FakeSSHServer(faults: faults)
        let transcript = TerminalTranscript()
        await #expect(throws: SSHClientError.self) {
            try await open(try pool(for: server), server, command: "true", transcript: transcript)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(transcript.ended == nil)
    }

    @Test func aRefusedProgramFailsTheOpen() async throws {
        var faults = FakeSSHServer.Faults()
        faults.refuseProgram = true
        let server = try FakeSSHServer(faults: faults)
        let pool = try pool(for: server)
        let transcript = TerminalTranscript()
        do {
            try await open(pool, server, command: "true", transcript: transcript)
            Issue.record("expected the open to fail")
        } catch SSHClientError.channelFailed(let detail) {
            #expect(detail.contains("refused"))
        }
        #expect(transcript.ended == nil)
        // The failed channel doesn't leak a pool slot.
        try await waitForChannels(pool, server.target, total: 0)
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        var faults = FakeSSHServer.Faults()
        faults.ignoreRequests = true
        let server = try FakeSSHServer(faults: faults)
        let pool = try pool(for: server, startTimeout: .milliseconds(500))
        let started = ContinuousClock.now
        do {
            try await open(pool, server, command: "true", transcript: TerminalTranscript())
            Issue.record("expected the open to time out")
        } catch SSHClientError.channelFailed(let detail) {
            #expect(detail.contains("timed out starting"), "\(detail)")
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(450) && elapsed < .seconds(5))
        try await waitForChannels(pool, server.target, total: 0)
    }

    @Test func aDroppedConnectionEndsTheSessionAsLost() async throws {
        var faults = FakeSSHServer.Faults()
        faults.dropConnectionAfterBytes = 64 * 1024
        let server = try FakeSSHServer(faults: faults)
        let transcript = TerminalTranscript()
        try await open(try pool(for: server), server, command: "stty raw -echo; yes", transcript: transcript)
        #expect(try await transcript.waitForEnd() == .connectionLost)
        #expect(transcript.receivedBytes > 0)
    }

    @Test func aDroppedNetworkEndsEverySessionOnIt() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        let transcripts = (0..<3).map { _ in TerminalTranscript() }
        for transcript in transcripts {
            try await open(pool, server, command: "echo up; sleep 30", transcript: transcript)
            try await transcript.waitFor("up")
        }
        server.dropAllConnections()
        for transcript in transcripts {
            #expect(try await transcript.waitForEnd() == .connectionLost)
        }
    }

    @Test func aMissingExitStatusIsALostSession() async throws {
        var faults = FakeSSHServer.Faults()
        faults.omitExitStatus = true
        let server = try FakeSSHServer(faults: faults)
        let transcript = TerminalTranscript()
        try await open(try pool(for: server), server, command: "exit 3", transcript: transcript)
        #expect(try await transcript.waitForEnd() == .connectionLost)
    }

    @Test func closingDuringAFloodNeverCrashes() async throws {
        // Data the server sends after our close must not trigger a window
        // adjust (NIOSSH precondition; see ThirdParty/swift-nio-ssh/RELAY.md).
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        for _ in 0..<25 {
            let transcript = TerminalTranscript()
            let session = try await open(pool, server, command: "stty raw -echo; yes flood-data", transcript: transcript)
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...30)))
            session.close()
            #expect(try await transcript.waitForEnd() == .closedLocally)
        }
        try await waitForChannels(pool, server.target, total: 0)
    }

    @Test func consumingOutputAfterClosingNeverReadsTheClosedChannel() async throws {
        // The exact app sequence: reads held at the high-water mark, the
        // terminal closes, then its dropped feeds still report consumption.
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        for _ in 0..<10 {
            let transcript = TerminalTranscript(autoConsume: false)
            let session = try await open(pool, server, command: "stty raw -echo; yes held-data", transcript: transcript,
                                         highWaterMark: 16 * 1024, lowWaterMark: 4 * 1024)
            try await transcript.waitUntil("reads held") { $0.receivedBytes >= 16 * 1024 }
            session.close()
            session.outputConsumed(transcript.receivedBytes)
            #expect(try await transcript.waitForEnd() == .closedLocally)
        }
        try await waitForChannels(pool, server.target, total: 0)
    }

    @Test func closingHangsUpTheRemoteProgram() async throws {
        let server = try FakeSSHServer()
        let transcript = TerminalTranscript()
        let session = try await open(try pool(for: server), server, command: "echo up; sleep 30", transcript: transcript)
        try await transcript.waitFor("up")
        let pid = try #require(server.sessions.first?.pid)
        session.close()
        #expect(try await transcript.waitForEnd() == .closedLocally)
        // The pty hangup ends the program.
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) != 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(transcript.endCallCount == 1)
    }

    // MARK: Pooling

    func waitForChannels(_ pool: SSHConnectionPool, _ target: SSHTarget, total: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await pool.activeChannels(for: target).reduce(0, +) != total {
            guard ContinuousClock.now < deadline else {
                Issue.record("channels: \(await pool.activeChannels(for: target)), expected \(total)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func terminalsShareConnectionsWithCommandsAndReleaseTheirChannels() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        var sessions: [SSHTerminalSession] = []
        var transcripts: [TerminalTranscript] = []
        for _ in 0..<6 {
            let transcript = TerminalTranscript()
            sessions.append(try await open(pool, server, command: "echo up; sleep 30", transcript: transcript))
            transcripts.append(transcript)
        }
        // Commands still run alongside, on the same connection.
        let result = try await pool.exec(target: server.target, command: "echo hi", stdin: Data(), timeout: .seconds(10))
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("hi"))
        #expect(server.connectionCount == 1)

        // Past the per-connection channel limit, a second connection opens.
        for _ in 0..<4 {
            let transcript = TerminalTranscript()
            sessions.append(try await open(pool, server, command: "echo up; sleep 30", transcript: transcript))
            transcripts.append(transcript)
        }
        #expect(server.connectionCount == 2)
        try await waitForChannels(pool, server.target, total: 10)

        for session in sessions { session.close() }
        for transcript in transcripts { #expect(try await transcript.waitForEnd() == .closedLocally) }
        try await waitForChannels(pool, server.target, total: 0)
    }

    @Test func aCallerCancelledAfterTheChannelOpenedNeverHearsOfTheSession() async throws {
        var faults = FakeSSHServer.Faults()
        faults.programReplyDelay = .seconds(2)
        let server = try FakeSSHServer(faults: faults)
        let pool = try pool(for: server)
        let transcript = TerminalTranscript()
        let task = Task {
            try await pool.openTerminal(
                target: server.target,
                request: SSHTerminalRequest(size: SSHTerminalSize(columns: 80, rows: 24), command: "echo started; sleep 30"),
                onOutput: transcript.onOutput, onEnd: transcript.onEnd)
        }
        // Cancelled once the server has started the program but not yet
        // answered: the channel is open, the session not yet handed out.
        let started = ContinuousClock.now + .seconds(10)
        while server.sessions.first?.pid == nil, ContinuousClock.now < started {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await waitForChannels(pool, server.target, total: 0)
        let pid = try #require(server.sessions.first?.pid)
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(pid, 0) != 0)
        #expect(transcript.endCallCount == 0)
    }

    @Test func aSessionThatEndsBeforeItIsHandedOutStillReportsItsEnd() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        for _ in 0..<20 {
            let transcript = TerminalTranscript()
            try await open(pool, server, command: "exit 4", transcript: transcript)
            #expect(try await transcript.waitForEnd() == .exited(4))
            #expect(transcript.endCallCount == 1)
        }
    }

    @Test func aChannelConfirmedAfterTheTimeoutIsClosedAndCostsNothing() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server, openTimeout: .milliseconds(300))
        // A live terminal on the same connection must survive the late one.
        let survivor = TerminalTranscript()
        try await open(pool, server, command: "echo alive; sleep 30", transcript: survivor)
        try await survivor.waitFor("alive")

        server.faults.channelOpenDelay = .milliseconds(800)
        let late = TerminalTranscript()
        do {
            try await open(pool, server, command: "echo ghost-$((1+1)); sleep 30", transcript: late)
            Issue.record("expected the open to time out")
        } catch let error as SSHClientError {
            #expect("\(error)".contains("timed out opening"))
        }
        server.faults.channelOpenDelay = nil
        // Past the late confirmation: the channel was closed, never started.
        try await Task.sleep(for: .milliseconds(1200))
        let startedGhosts = server.sessions.filter { record in
            (record.command ?? "").contains("ghost") && record.pid != nil
        }
        #expect(startedGhosts.isEmpty)
        #expect(late.endCallCount == 0)
        #expect(survivor.ended == nil)
        // Exactly the survivor's channel remains, on the connection it had:
        // a slow server isn't a reason to abandon a shared connection.
        try await waitForChannels(pool, server.target, total: 1)
        #expect(await pool.activeChannels(for: server.target).count == 1)
        #expect(server.connectionCount == 1)
    }

    @Test func aTimeoutOnAnOtherwiseUnusedConnectionStartsFreshNextTime() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server, startTimeout: .milliseconds(300))
        _ = try await pool.exec(target: server.target, command: "true", stdin: Data(), timeout: .seconds(10))
        #expect(server.connectionCount == 1)
        server.faults.ignoreRequests = true
        await #expect(throws: SSHClientError.self) {
            try await open(pool, server, command: "true", transcript: TerminalTranscript())
        }
        server.faults.ignoreRequests = false
        let transcript = TerminalTranscript()
        try await open(pool, server, command: "echo fresh", transcript: transcript)
        #expect(try await transcript.waitForEnd() == .exited(0))
        #expect(server.connectionCount == 2)
    }

    @Test func openingWhileTheConnectionDropsFailsCleanly() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        for _ in 0..<15 {
            // Warm a pooled connection, then drop it as the next open starts.
            _ = try await pool.exec(target: server.target, command: "true", stdin: Data(), timeout: .seconds(10))
            server.dropAllConnections()
            let transcript = TerminalTranscript()
            if let session = try? await open(pool, server, command: "echo ok", transcript: transcript) {
                _ = session
                _ = try await transcript.waitForEnd()
            }
        }
        try await waitForChannels(pool, server.target, total: 0)
    }

    @Test func aCancelledOpenLeavesNothingBehind() async throws {
        let server = try FakeSSHServer()
        let pool = try pool(for: server)
        let transcript = TerminalTranscript()
        let task = Task {
            try await pool.openTerminal(
                target: server.target,
                request: SSHTerminalRequest(size: SSHTerminalSize(columns: 80, rows: 24), command: "sleep 30"),
                onOutput: transcript.onOutput, onEnd: transcript.onEnd)
        }
        task.cancel()
        _ = try? await task.value
        try await waitForChannels(pool, server.target, total: 0)
    }
}

/// The same session behavior against a real OpenSSH sshd (the system's,
/// run as this user on a loopback port).
@Suite("SSH terminal sessions (real sshd)", .serialized)
struct SSHTerminalSessionSSHDTests {
    static let sshd: TestSSHD? = try? TestSSHD()

    let scratch: URL

    init() throws {
        scratch = try makeScratchDirectory("sshd-term")
    }

    func sshd() throws -> TestSSHD {
        try #require(Self.sshd, "sshd must be available to run these tests")
    }

    func pool(_ sshd: TestSSHD) -> SSHConnectionPool {
        var options = SSHConnectionPool.Options()
        options.knownHostsFiles = [sshd.knownHostsPath]
        options.agent = nil
        options.defaultKeyFiles = []
        return SSHConnectionPool(options: options)
    }

    @discardableResult
    func open(
        _ sshd: TestSSHD,
        _ pool: SSHConnectionPool,
        command: String?,
        size: SSHTerminalSize = SSHTerminalSize(columns: 80, rows: 24),
        environment: [(String, String)] = [],
        transcript: TerminalTranscript,
        highWaterMark: Int = SSHTerminalSession.defaultHighWaterMark
    ) async throws -> SSHTerminalSession {
        let session = try await pool.openTerminal(
            target: sshd.target,
            request: SSHTerminalRequest(size: size, command: command, environment: environment),
            highWaterMark: highWaterMark, lowWaterMark: highWaterMark / 4,
            onOutput: transcript.onOutput, onEnd: transcript.onEnd)
        transcript.attach(session)
        return session
    }

    @Test func runsOnARealPTYWithTheRequestedSizeAndTerm() async throws {
        let sshd = try sshd()
        let transcript = TerminalTranscript()
        try await open(sshd, pool(sshd), command: "stty size; tty; echo TERM=$TERM; stty -a | grep -o 'erase = [^;]*'",
                       size: SSHTerminalSize(columns: 101, rows: 37), transcript: transcript)
        #expect(try await transcript.waitForEnd() == .exited(0))
        #expect(transcript.text.contains("37 101"))
        #expect(transcript.text.contains("/dev/tty"))
        #expect(transcript.text.contains("TERM=xterm-256color"))
        // Our terminal modes: DEL is erase, matching what the terminal sends.
        #expect(transcript.text.contains("erase = ^?"))
    }

    @Test func exitStatusesAndSignals() async throws {
        let sshd = try sshd()
        let pool = pool(sshd)
        for (command, expected) in [("exit 0", Int32(0)), ("exit 9", 9), ("kill -INT $$", 130), ("kill -KILL $$", 137)] {
            let transcript = TerminalTranscript()
            try await open(sshd, pool, command: command, transcript: transcript)
            #expect(try await transcript.waitForEnd() == .exited(expected), "\(command)")
        }
    }

    @Test func aLoginShellRunsInteractively() async throws {
        let sshd = try sshd()
        let transcript = TerminalTranscript()
        let session = try await open(sshd, pool(sshd), command: nil, transcript: transcript)
        // The user's own shell and startup files: wait for any prompt by
        // asking for a marker.
        session.write(Data("echo RELAY_$((40+2))_OK\r".utf8))
        try await transcript.waitFor("RELAY_42_OK", timeout: .seconds(30))
        session.write(Data("exit\r".utf8))
        #expect(try await transcript.waitForEnd(timeout: .seconds(30)) == .exited(0))
    }

    @Test func windowChangeReachesTheProgram() async throws {
        let sshd = try sshd()
        let transcript = TerminalTranscript()
        let session = try await open(
            sshd, pool(sshd),
            command: "/bin/sh -c \"trap 'echo winch \\$(stty size)' WINCH; echo ready; while :; do sleep 0.02; done\"",
            transcript: transcript)
        try await transcript.waitFor("ready")
        session.resize(SSHTerminalSize(columns: 150, rows: 50))
        try await transcript.waitFor("winch 50 150")
        session.close()
        #expect(try await transcript.waitForEnd() == .closedLocally)
    }

    @Test func controlCInterruptsTheForegroundProgram() async throws {
        let sshd = try sshd()
        let transcript = TerminalTranscript()
        let session = try await open(
            sshd, pool(sshd),
            command: "/bin/sh -c 'trap \"echo interrupted; exit 5\" INT; echo ready; while :; do sleep 0.02; done'",
            transcript: transcript)
        try await transcript.waitFor("ready")
        session.write(Data([0x03]))
        #expect(try await transcript.waitForEnd() == .exited(5))
        #expect(transcript.text.contains("interrupted"))
    }

    @Test func forwardsAcceptedEnvironment() async throws {
        let sshd = try sshd()
        let transcript = TerminalTranscript()
        try await open(sshd, pool(sshd), command: "echo got=$RELAY_PROBE",
                       environment: [("RELAY_PROBE", "from-client")], transcript: transcript)
        _ = try await transcript.waitForEnd()
        #expect(transcript.text.contains("got=from-client"))
    }

    @Test func largeOutputArrivesIntactUnderFlowControl() async throws {
        let sshd = try sshd()
        let file = scratch.appendingPathComponent("blob")
        let blob = try writeRandomFile(at: file, count: 8 << 20, seed: 7)
        let transcript = TerminalTranscript(autoConsume: false)
        let session = try await open(sshd, pool(sshd), command: "stty raw -echo; cat '\(file.path)'",
                                     transcript: transcript, highWaterMark: 64 * 1024)
        try await transcript.waitUntil("some output") { $0.receivedBytes > 0 }
        try await Task.sleep(for: .milliseconds(500))
        // sshd stops once the window is full: little has arrived.
        #expect(try await session.unconsumedBytes() <= 64 * 1024 + (128 << 10) + 64 << 10)
        #expect(transcript.receivedBytes < 1 << 20)
        transcript.setAutoConsume(true)
        #expect(try await transcript.waitForEnd(timeout: .seconds(60)) == .exited(0))
        #expect(transcript.output == blob)
    }

    @Test func inputIsDeliveredByteExact() async throws {
        let sshd = try sshd()
        let transcript = TerminalTranscript()
        let session = try await open(
            sshd, pool(sshd),
            command: "stty raw -echo; echo ready; head -c 4096 | shasum -a 256; echo done",
            transcript: transcript)
        try await transcript.waitFor("ready")
        var input = Data()
        for i in 0..<4096 { input.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7)) }
        // In small pieces, as typing and pastes arrive.
        for chunk in stride(from: 0, to: input.count, by: 100) {
            session.write(input.subdata(in: chunk..<min(chunk + 100, input.count)))
        }
        try await transcript.waitFor("done")
        let digest = try shasum(input)
        #expect(transcript.text.contains(digest))
    }

    @Test func aKilledServerSessionIsALostConnection() async throws {
        let sshd = try sshd()
        let transcript = TerminalTranscript()
        // The command's parent is this connection's sshd process.
        try await open(sshd, pool(sshd), command: "echo before; sleep 0.2; kill -9 $PPID; sleep 5", transcript: transcript)
        #expect(try await transcript.waitForEnd() == .connectionLost)
        #expect(transcript.text.contains("before"))
    }

    @Test func commandsKeepStderrAndReportSignals() async throws {
        let sshd = try sshd()
        // No pty for commands: stderr stays separate.
        let result = try await pool(sshd).exec(
            target: sshd.target, command: "echo out; echo err >&2; kill -TERM $$", stdin: Data(), timeout: .seconds(10))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
        #expect(result.exitCode == 128 + 15)
    }

    @Test func authenticatesWithAKeyHeldByTheAgent() async throws {
        let sshd = try sshd()
        // A throwaway ssh-agent holding the client key: the key file is then
        // used through the agent, as with a passphrase-protected key.
        let socket = scratch.appendingPathComponent("agent.sock").path
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { agent.terminate() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: socket), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // A copy of the key whose private half is deleted once the agent
        // has it: only the agent can sign, so success proves it was used.
        let keyPath = scratch.appendingPathComponent("agent_key").path
        try FileManager.default.copyItem(atPath: sshd.clientKeyPath, toPath: keyPath)
        try FileManager.default.copyItem(atPath: sshd.clientKeyPath + ".pub", toPath: keyPath + ".pub")
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        add.arguments = ["-q", keyPath]
        add.environment = ["SSH_AUTH_SOCK": socket]
        add.standardError = FileHandle.nullDevice
        try add.run()
        add.waitUntilExit()
        try #require(add.terminationStatus == 0)
        try FileManager.default.removeItem(atPath: keyPath)

        var options = SSHConnectionPool.Options()
        options.knownHostsFiles = [sshd.knownHostsPath]
        options.agent = SSHAgent(socketPath: socket)
        options.defaultKeyFiles = []
        let offers = SSHConnectionPool.authOffers(for: .keyFile(path: keyPath), agent: options.agent, defaultKeyFiles: [])
        #expect(offers.count == 1)
        var target = sshd.target
        target.credentials = .keyFile(path: keyPath)
        let transcript = TerminalTranscript()
        let session = try await SSHConnectionPool(options: options).openTerminal(
            target: target, request: SSHTerminalRequest(size: SSHTerminalSize(columns: 80, rows: 24), command: "echo via-agent"),
            onOutput: transcript.onOutput, onEnd: transcript.onEnd)
        transcript.attach(session)
        #expect(try await transcript.waitForEnd() == .exited(0))
        #expect(transcript.text.contains("via-agent"))
    }

    func shasum(_ data: Data) throws -> String {
        let url = scratch.appendingPathComponent("input-\(UUID().uuidString)")
        try data.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return String(out.prefix(64))
    }
}
