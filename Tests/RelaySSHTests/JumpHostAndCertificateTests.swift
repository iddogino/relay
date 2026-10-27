import Foundation
import RelayTestSupport
import Testing
@testable import RelaySSH

/// Connecting through jump hosts (ProxyJump) and signing in with OpenSSH
/// certificates — against real sshd instances, since what matters is what
/// OpenSSH accepts.
@Suite("Jump hosts and certificates", .serialized)
struct JumpHostAndCertificateTests {
    /// Jump hosts log the forwards they open (debug level).
    static func jumpSSHD(_ extra: [String] = []) throws -> TestSSHD {
        try TestSSHD(extraConfig: ["LogLevel DEBUG1"] + extra)
    }

    func pool(knownHosts: [String], idleTimeout: Duration = .seconds(120)) -> SSHConnectionPool {
        var options = SSHConnectionPool.Options()
        options.knownHostsFiles = knownHosts
        options.agent = nil
        options.defaultKeyFiles = []
        options.idleTimeout = idleTimeout
        return SSHConnectionPool(options: options)
    }

    func run(_ pool: SSHConnectionPool, _ target: SSHTarget, _ command: String) async throws -> String {
        let result = try await pool.exec(target: target, command: command, stdin: Data(), timeout: .seconds(30))
        #expect(result.exitCode == 0)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    @Test func connectsThroughAJumpHost() async throws {
        let jump = try Self.jumpSSHD()
        let target = try TestSSHD()
        defer { jump.stop(); target.stop() }
        let pool = pool(knownHosts: [jump.knownHostsPath, target.knownHostsPath])
        var via = target.target
        via.jumps = [jump.target]

        #expect(try await run(pool, via, "echo through") == "through\n")
        // The jump host opened a forward to the target; the target saw a
        // sign-in of its own (end to end, not through the jump's session).
        #expect(jump.log.contains("direct-tcpip"))
        #expect(jump.log.contains("port \(target.port)"))
        #expect(target.log.contains("Accepted publickey"))
    }

    @Test func chainsJumpHostsInOrder() async throws {
        let first = try Self.jumpSSHD()
        let second = try Self.jumpSSHD()
        let target = try TestSSHD()
        defer { first.stop(); second.stop(); target.stop() }
        let pool = pool(knownHosts: [first.knownHostsPath, second.knownHostsPath, target.knownHostsPath])
        var via = target.target
        via.jumps = [first.target, second.target]

        #expect(try await run(pool, via, "echo two hops") == "two hops\n")
        #expect(first.log.contains("port \(second.port)"))
        #expect(!first.log.contains("port \(target.port)"))
        #expect(second.log.contains("port \(target.port)"))
    }

    @Test func aJumpConnectionIsSharedAndLetGoWithItsUsers() async throws {
        let jump = try Self.jumpSSHD()
        let one = try TestSSHD()
        let two = try TestSSHD()
        defer { jump.stop(); one.stop(); two.stop() }
        let pool = pool(knownHosts: [jump.knownHostsPath, one.knownHostsPath, two.knownHostsPath], idleTimeout: .seconds(1))
        var viaOne = one.target
        viaOne.jumps = [jump.target]
        var viaTwo = two.target
        viaTwo.jumps = [jump.target]

        _ = try await run(pool, viaOne, "true")
        _ = try await run(pool, viaTwo, "true")
        // One connection to the jump host carries both forwards.
        #expect(await pool.activeChannels(for: jump.target) == [2])
        #expect(jump.log.components(separatedBy: "Accepted publickey").count - 1 == 1)

        // Idle targets close, and with them their forwards; then the jump
        // connection itself goes idle and closes.
        for _ in 0..<40 where await !pool.activeChannels(for: jump.target).isEmpty {
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(await pool.activeChannels(for: viaOne).isEmpty)
        #expect(await pool.activeChannels(for: jump.target).isEmpty)
    }

    @Test func aJumpHostThatWontForwardLeavesTheTargetUnreachable() async throws {
        let jump = try Self.jumpSSHD(["AllowTcpForwarding no"])
        let target = try TestSSHD()
        defer { jump.stop(); target.stop() }
        let pool = pool(knownHosts: [jump.knownHostsPath, target.knownHostsPath])
        var via = target.target
        via.jumps = [jump.target]
        do {
            _ = try await run(pool, via, "true")
            Issue.record("connected through a jump host that forbids forwarding")
        } catch SSHClientError.unreachable(let detail) {
            #expect(detail.contains("couldn\u{2019}t connect to 127.0.0.1 port \(target.port)"))
        }
    }

    @Test func aJumpHostsOwnFailureIsNamed() async throws {
        let jump = try Self.jumpSSHD()
        let target = try TestSSHD()
        defer { jump.stop(); target.stop() }
        let pool = pool(knownHosts: [jump.knownHostsPath, target.knownHostsPath])
        var via = target.target
        // The target's key, which the jump host doesn't accept.
        via.jumps = [SSHTarget(host: "127.0.0.1", port: jump.port, username: NSUserName(),
                               credentials: .keyFile(path: target.clientKeyPath))]
        do {
            _ = try await run(pool, via, "true")
            Issue.record("signed in to a jump host with the wrong key")
        } catch SSHClientError.handshakeFailed(let detail) {
            #expect(detail.hasPrefix("jump host 127.0.0.1"))
            #expect(detail.contains("authentication failed"))
        }
    }

    @Test func theTargetsHostKeyIsCheckedToo() async throws {
        let jump = try Self.jumpSSHD()
        let target = try TestSSHD()
        defer { jump.stop(); target.stop() }
        // Only the jump host is known.
        let pool = pool(knownHosts: [jump.knownHostsPath])
        var via = target.target
        via.jumps = [jump.target]
        await #expect {
            _ = try await run(pool, via, "true")
        } throws: { error in
            guard case SSHClientError.hostKeyNotTrusted(.unknown, let presented) = error else { return false }
            let known = (try? String(contentsOfFile: target.knownHostsPath, encoding: .utf8)) ?? ""
            return known.contains(presented)
        }
    }

    @Test func aTerminalRunsThroughAJumpHost() async throws {
        let jump = try Self.jumpSSHD()
        let target = try TestSSHD()
        defer { jump.stop(); target.stop() }
        let pool = pool(knownHosts: [jump.knownHostsPath, target.knownHostsPath])
        var via = target.target
        via.jumps = [jump.target]
        let output = Collected()
        let ended = Collected()
        let session = try await pool.openTerminal(
            target: via,
            request: SSHTerminalRequest(size: SSHTerminalSize(columns: 80, rows: 24), command: "printf 'tty:'; tty"),
            onOutput: { output.append($0) },
            onEnd: { _ in ended.append(Data("end".utf8)) })
        defer { session.close() }
        for _ in 0..<100 where !ended.text.contains("end") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(output.text.contains("tty:/dev/"))
    }

    // MARK: Certificates

    /// An sshd that accepts only certificates signed by a fresh CA, and a
    /// user key with a certificate valid for `validity`.
    func certificateSetup(validity: String = "-5m:+1h") throws -> (TestSSHD, key: String, certificate: String) {
        let dir = try makeScratchDirectory("ssh-cert")
        let ca = dir.appendingPathComponent("ca").path
        let key = dir.appendingPathComponent("user").path
        try keygen(["-q", "-t", "ed25519", "-N", "", "-C", "relay-test-ca", "-f", ca])
        try keygen(["-q", "-t", "ed25519", "-N", "", "-C", "relay-test-user", "-f", key])
        try keygen(["-q", "-s", ca, "-I", "relay-test", "-n", NSUserName(), "-V", validity, key + ".pub"])
        let sshd = try TestSSHD(extraConfig: ["TrustedUserCAKeys \(ca).pub", "AuthorizedKeysFile none"])
        return (sshd, key, key + "-cert.pub")
    }

    func keygen(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitForExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func signsInWithACertificate() async throws {
        let (sshd, key, certificate) = try certificateSetup()
        defer { sshd.stop() }
        let pool = pool(knownHosts: [sshd.knownHostsPath])
        let target = SSHTarget(host: "127.0.0.1", port: sshd.port, username: NSUserName(),
                               credentials: .keyFile(path: key, certificatePath: certificate))
        #expect(try await run(pool, target, "echo certified") == "certified\n")
        #expect(sshd.log.contains("Accepted publickey") && sshd.log.contains("ED25519-CERT"))

        // The same key without its certificate isn't accepted.
        let plain = SSHTarget(host: "127.0.0.1", port: sshd.port, username: NSUserName(), credentials: .keyFile(path: key))
        await #expect(throws: SSHClientError.authenticationFailed) {
            _ = try await run(pool, plain, "true")
        }
    }

    @Test func anExpiredCertificateIsRefused() async throws {
        let (sshd, key, certificate) = try certificateSetup(validity: "-2h:-1h")
        defer { sshd.stop() }
        let pool = pool(knownHosts: [sshd.knownHostsPath])
        let target = SSHTarget(host: "127.0.0.1", port: sshd.port, username: NSUserName(),
                               credentials: .keyFile(path: key, certificatePath: certificate))
        await #expect(throws: SSHClientError.authenticationFailed) {
            _ = try await run(pool, target, "true")
        }
    }

    @Test func aMissingCertificateFallsBackToTheKey() {
        // An unreadable certificate isn't fatal: the key is still offered.
        let offers = SSHConnectionPool.authOffers(
            for: .keyFile(path: Self.plainKey, certificatePath: "/nonexistent-cert.pub"), agent: nil, defaultKeyFiles: [])
        #expect(offers.count == 1)
    }

    static let plainKey: String = {
        let path = NSTemporaryDirectory() + "relay-plain-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", path]
        try? process.run()
        process.waitForExit()
        return path
    }()

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
