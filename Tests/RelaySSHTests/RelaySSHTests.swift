import Crypto
import Foundation
import RelayTestSupport
import NIOCore
@preconcurrency import NIOSSH
import Testing
@testable import RelaySSH

@Suite("Built-in SSH client")
struct RelaySSHTests {
    // MARK: known_hosts

    static let keyA = Data([1, 2, 3, 4])
    static let keyB = Data([5, 6, 7, 8])

    static func line(_ patterns: String, _ type: String = "ssh-ed25519", _ key: Data = keyA, marker: String = "") -> String {
        "\(marker.isEmpty ? "" : marker + " ")\(patterns) \(type) \(key.base64EncodedString()) comment"
    }

    @Test func trustsAMatchingKeyAndFlagsAChangedOne() {
        let hosts = KnownHosts(entries: KnownHosts.parse([
            Self.line("box,10.0.0.5"),
            Self.line("other", "ssh-ed25519", Self.keyB),
        ].joined(separator: "\n")))
        #expect(hosts.verify(host: "box", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .trusted)
        #expect(hosts.verify(host: "BOX", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .trusted)
        #expect(hosts.verify(host: "box", port: 22, keyType: "ssh-ed25519", key: Self.keyB) == .changed)
        #expect(hosts.verify(host: "nowhere", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .unknown)
    }

    /// The client asks for the key types it knows a host by first, so a
    /// host presenting a key of another type has changed: calling it new
    /// would let someone in between trade the blocked "identity changed"
    /// for a first-time trust prompt, just by offering another type.
    @Test func aKnownHostPresentingAnotherKeyTypeHasChanged() {
        let hosts = KnownHosts(entries: KnownHosts.parse([
            Self.line("box"),
            Self.line("both"),
            Self.line("both", "ecdsa-sha2-nistp256", Self.keyB),
            // A type this client can't negotiate: it could never have
            // been presented, so another type isn't a change.
            Self.line("old", "ssh-rsa", Self.keyB),
            Self.line("gone", "ssh-ed25519", Self.keyA, marker: "@revoked"),
        ].joined(separator: "\n")))
        #expect(hosts.verify(host: "box", port: 22, keyType: "ecdsa-sha2-nistp256", key: Self.keyB) == .changed)
        #expect(hosts.verify(host: "both", port: 22, keyType: "ecdsa-sha2-nistp256", key: Self.keyB) == .trusted)
        #expect(hosts.verify(host: "both", port: 22, keyType: "ecdsa-sha2-nistp384", key: Self.keyB) == .changed)
        #expect(hosts.verify(host: "old", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .unknown)
        #expect(hosts.verify(host: "gone", port: 22, keyType: "ecdsa-sha2-nistp256", key: Self.keyB) == .unknown)

        #expect(hosts.knownKeyTypes(host: "box", port: 22) == ["ssh-ed25519"])
        #expect(Set(hosts.knownKeyTypes(host: "both", port: 22)) == ["ssh-ed25519", "ecdsa-sha2-nistp256"])
        #expect(hosts.knownKeyTypes(host: "old", port: 22) == [])
        #expect(hosts.knownKeyTypes(host: "gone", port: 22) == [])
        #expect(hosts.knownKeyTypes(host: "nowhere", port: 22) == [])
    }

    @Test func trustRefusesNamesKnownHostsWouldReadAsPatterns() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("relay-kh-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        let key = "ssh-ed25519 \(Self.keyA.base64EncodedString())"
        for name in ["*", "box*", "?", "!box", "|1|x|y", "@revoked", "#box", "a,b", "a b", ""] {
            #expect(throws: (any Error).self) { try KnownHosts.trust(host: name, port: 22, presentedKey: key, in: file) }
        }
        try KnownHosts.trust(host: "box.example.com", port: 22, presentedKey: key, in: file)
        try KnownHosts.trust(host: "fe80::1", port: 2222, presentedKey: key, in: file)
        let hosts = KnownHosts.load(files: [file])
        #expect(hosts.verify(host: "box.example.com", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .trusted)
        #expect(hosts.verify(host: "anything", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .unknown)
    }

    @Test func oneBadByteDoesntDropTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("relay-kh-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        var data = Data("# caf".utf8)
        data.append(0xE9) // Latin-1 é
        data.append(Data("\n\(Self.line("box"))\n\(Self.line("bad", marker: "@revoked"))\n".utf8))
        try data.write(to: URL(fileURLWithPath: file))
        let hosts = KnownHosts.load(files: [file])
        #expect(hosts.verify(host: "box", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .trusted)
        #expect(hosts.verify(host: "bad", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .revoked)
    }

    @Test func nonDefaultPortsUseBracketedNames() {
        let hosts = KnownHosts(entries: KnownHosts.parse(Self.line("[box]:2222")))
        #expect(hosts.verify(host: "box", port: 2222, keyType: "ssh-ed25519", key: Self.keyA) == .trusted)
        #expect(hosts.verify(host: "box", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .unknown)
    }

    @Test func matchesHashedEntries() {
        let salt = Data((0..<20).map { UInt8($0) })
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data("box".utf8), using: SymmetricKey(data: salt))
        let hashed = "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
        let hosts = KnownHosts(entries: KnownHosts.parse(Self.line(hashed)))
        #expect(hosts.verify(host: "box", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .trusted)
        #expect(hosts.verify(host: "box2", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .unknown)
    }

    @Test func wildcardsNegationAndMarkers() {
        let hosts = KnownHosts(entries: KnownHosts.parse([
            Self.line("*.lan,!evil.lan"),
            Self.line("revoked", marker: "@revoked"),
            Self.line("revoked"),
            Self.line("*", marker: "@cert-authority"),
            "# a comment",
            "garbage",
        ].joined(separator: "\n")))
        #expect(hosts.verify(host: "a.lan", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .trusted)
        #expect(hosts.verify(host: "evil.lan", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .unknown)
        #expect(hosts.verify(host: "revoked", port: 22, keyType: "ssh-ed25519", key: Self.keyA) == .revoked)
        #expect(KnownHosts.glob("h?st*", "host-1"))
        #expect(!KnownHosts.glob("h?st", "hst"))
    }

    // MARK: Key files

    static func keygen(type: String, passphrase: String = "") throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("id").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", type, "-N", passphrase, "-C", "", "-f", path]
        try process.run()
        process.waitForExit()
        return path
    }

    static func blob(_ key: NIOSSHPublicKey) -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        key.write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    @Test(arguments: ["ed25519", "ecdsa"])
    func loadsUnencryptedKeyFiles(type: String) throws {
        let path = try Self.keygen(type: type)
        let key = try OpenSSHKeyFile.load(path: path)
        #expect(Self.blob(key.publicKey) == OpenSSHKeyFile.publicKeyBlob(forPrivateKeyAt: path))
    }

    @Test func refusesEncryptedKeyFiles() throws {
        let path = try Self.keygen(type: "ed25519", passphrase: "secret phrase")
        #expect(throws: OpenSSHKeyFile.KeyFileError.encrypted) { try OpenSSHKeyFile.load(path: path) }
        // …but its .pub still identifies it for the agent.
        #expect(OpenSSHKeyFile.publicKeyBlob(forPrivateKeyAt: path) != nil)
    }

    @Test func authOffersFollowCredentials() throws {
        let path = try Self.keygen(type: "ed25519")
        #expect(SSHConnectionPool.authOffers(for: .keyFile(path: path), agent: nil, defaultKeyFiles: []).count == 1)
        #expect(SSHConnectionPool.authOffers(for: .automatic, agent: nil, defaultKeyFiles: [path, path]).count == 1)
        #expect(SSHConnectionPool.authOffers(for: .automatic, agent: nil, defaultKeyFiles: ["/nonexistent"]).isEmpty)
        if case .password(let password) = SSHConnectionPool.authOffers(for: .password("pw"), agent: nil, defaultKeyFiles: [path]).first {
            #expect(password.password == "pw")
        } else {
            Issue.record("expected a password offer")
        }
    }

    // MARK: Agent wire format

    @Test func splitsAgentBlobs() throws {
        var writer = SSHWireWriter()
        writer.writeString("ssh-ed25519")
        writer.writeString(Data(repeating: 7, count: 32))
        let (algorithm, rest) = try writer.data.splitSSHBlob()
        #expect(algorithm == "ssh-ed25519")
        // The remainder is passed through verbatim as the key's fields.
        #expect(rest.count == 4 + 32)
    }

    @Test func refusesAMissingAgentSocket() {
        let agent = SSHAgent(socketPath: "/nonexistent/agent.sock")
        #expect(throws: SSHAgent.AgentError.self) { try agent.identities() }
    }
}
