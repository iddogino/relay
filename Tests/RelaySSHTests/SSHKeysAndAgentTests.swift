import Darwin
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import RelayTestSupport
import Testing
@testable import RelaySSH

/// Keys and ssh-agent, with the real OpenSSH tools: every key type the
/// client signs with — through the agent against the real sshd, and from
/// files — and the agent socket's failure paths.
@Suite("SSH keys and agent", .serialized)
struct SSHKeysAndAgentTests {
    static let sshd: TestSSHD? = try? TestSSHD()

    let scratch: URL

    init() throws {
        scratch = try makeScratchDirectory("keys")
    }

    @discardableResult
    func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func keygen(_ name: String, _ arguments: [String]) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        #expect(try run("/usr/bin/ssh-keygen", ["-q", "-N", "", "-C", "", "-f", path] + arguments) == 0)
        return path
    }

    /// A throwaway agent holding `keys`; stopped when `body` returns.
    func withAgent<R>(holding keys: [String], _ body: (SSHAgent) async throws -> R) async throws -> R {
        let socket = scratch.appendingPathComponent("agent-\(UUID().uuidString.prefix(6)).sock").path
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
        for key in keys {
            #expect(try run("/usr/bin/ssh-add", ["-q", key], environment: ["SSH_AUTH_SOCK": socket]) == 0)
        }
        return try await body(SSHAgent(socketPath: socket))
    }

    // MARK: Agent signing, end to end

    @Test(arguments: [("ecdsa256", ["-t", "ecdsa", "-b", "256"], "ecdsa-sha2-nistp256"),
                      ("ecdsa384", ["-t", "ecdsa", "-b", "384"], "ecdsa-sha2-nistp384"),
                      ("ecdsa521", ["-t", "ecdsa", "-b", "521"], "ecdsa-sha2-nistp521"),
                      ("ed25519", ["-t", "ed25519"], "ssh-ed25519")])
    func theAgentSignsWithEachKeyTypeTheServerAccepts(name: String, keygenArguments: [String], algorithm: String) async throws {
        let sshd = try #require(Self.sshd, "sshd must be available")
        let key = try keygen(name, keygenArguments)
        // Authorize this key on the test server (sshd reads the file per login).
        let authorized = try FileHandle(forWritingTo: sshd.directory.appendingPathComponent("authorized_keys"))
        authorized.seekToEndOfFile()
        authorized.write(try Data(contentsOf: URL(fileURLWithPath: key + ".pub")))
        try authorized.close()
        // The private half goes: only the agent can sign.
        try await withAgent(holding: [key]) { agent in
            try FileManager.default.removeItem(atPath: key)
            let identities = try agent.identities()
            #expect(identities.map(\.algorithm) == [algorithm])

            var options = SSHConnectionPool.Options()
            options.knownHostsFiles = [sshd.knownHostsPath]
            options.agent = agent
            options.defaultKeyFiles = []
            var target = sshd.target
            target.credentials = .automatic
            let result = try await SSHConnectionPool(options: options).exec(
                target: target, command: "echo signed-by-agent", stdin: Data(), timeout: .seconds(15))
            #expect(String(decoding: result.stdout, as: UTF8.self).contains("signed-by-agent"))
        }
    }

    @Test func rsaAgentKeysAreNotOffered() async throws {
        // NIOSSH would label them ssh-rsa (SHA-1), which servers refuse.
        let key = try keygen("rsa", ["-t", "rsa", "-b", "2048"])
        try await withAgent(holding: [key]) { agent in
            let identity = try #require(try agent.identities().first)
            #expect(identity.algorithm == "ssh-rsa")
            #expect(AgentKeys.privateKey(for: identity, agent: agent) == nil)
            #expect(SSHConnectionPool.authOffers(for: .automatic, agent: agent, defaultKeyFiles: []).isEmpty)
        }
    }

    @Test func agentKeyTypesAreSignOnly() throws {
        // The client only signs; verifying and parsing are the server's job.
        let publicKey = AgentPublicKey<AgentKeys.P256>(keyFields: Data([1, 2, 3]))
        #expect(publicKey.rawRepresentation == Data([1, 2, 3]))
        #expect(AgentPublicKey<AgentKeys.P256>.publicKeyPrefix == "ecdsa-sha2-nistp256")
        let signature = AgentSignature<AgentKeys.P384>(signatureFields: Data([4]))
        #expect(signature.rawRepresentation == Data([4]))
        #expect(!publicKey.isValidSignature(signature, for: Data()))
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        #expect(throws: AgentKeyError.self) { _ = try AgentPublicKey<AgentKeys.P256>.read(from: &buffer) }
        #expect(throws: AgentKeyError.self) { _ = try AgentSignature<AgentKeys.P256>.read(from: &buffer) }
        #expect(AgentPrivateKey<AgentKeys.P521>.keyPrefix == "ecdsa-sha2-nistp521")
    }

    // MARK: Key files

    @Test(arguments: [["-t", "ecdsa", "-b", "384"], ["-t", "ecdsa", "-b", "521"]])
    func loadsLargerECDSAKeyFiles(arguments: [String]) throws {
        let path = try keygen("ecdsa-\(arguments.last!)", arguments)
        let key = try OpenSSHKeyFile.load(path: path)
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.publicKey.write(to: &buffer)
        #expect(Data(buffer.readableBytesView) == OpenSSHKeyFile.publicKeyBlob(forPrivateKeyAt: path))
    }

    @Test func refusesKeyFilesItCannotUse() throws {
        let rsa = try keygen("rsa-file", ["-t", "rsa", "-b", "2048"])
        #expect(throws: OpenSSHKeyFile.KeyFileError.unsupportedKeyType("ssh-rsa")) { try OpenSSHKeyFile.load(path: rsa) }

        let pem = try keygen("pem-file", ["-t", "ecdsa", "-m", "PEM"])
        #expect(throws: OpenSSHKeyFile.KeyFileError.notOpenSSHFormat) { try OpenSSHKeyFile.load(path: pem) }

        let header = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        let footer = "\n-----END OPENSSH PRIVATE KEY-----\n"
        #expect(throws: OpenSSHKeyFile.KeyFileError.malformed) {
            try OpenSSHKeyFile.parse(header + Data("not a key".utf8).base64EncodedString() + footer)
        }
        // A real key cut short: the right magic, then not enough data.
        let good = try String(contentsOfFile: try keygen("cut", ["-t", "ed25519"]), encoding: .utf8)
        let body = good.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let truncated = Data(base64Encoded: body)!.prefix(60)
        #expect(throws: OpenSSHKeyFile.KeyFileError.malformed) {
            try OpenSSHKeyFile.parse(header + truncated.base64EncodedString() + footer)
        }
    }

    // MARK: Agent socket

    @Test func anOverlongSocketPathIsUnavailable() {
        let agent = SSHAgent(socketPath: "/tmp/" + String(repeating: "x", count: 200))
        #expect(throws: SSHAgent.AgentError.self) { try agent.identities() }
    }

    @Test func socketFailuresAreReported() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        var on: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        close(fds[1])
        // The agent went away: reads see the close, writes fail.
        #expect(throws: SSHAgent.AgentError.self) { _ = try SSHAgent.readExactly(fd: fds[0], count: 4) }
        #expect(throws: SSHAgent.AgentError.self) { try SSHAgent.writeAll(fd: fds[0], data: Data([1, 2, 3])) }
        close(fds[0])
    }

    @Test func wireReaderKnowsWhenItIsDone() throws {
        var writer = SSHWireWriter()
        writer.writeString("x")
        var reader = SSHWireReader(writer.data)
        #expect(!reader.isAtEnd)
        _ = try reader.readString()
        #expect(reader.isAtEnd)
    }
}
