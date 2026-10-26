import CryptoKit
import Foundation
@preconcurrency import NIOSSH
import RelayTestSupport
import Testing
@testable import RelaySSH

/// Relay's own keys: the stores, signing in with them against the real
/// sshd (Secure Enclave keys included), and trusting a new host key.
@Suite("Relay SSH keys", .serialized)
struct SSHKeyStoreTests {
    static let sshd: TestSSHD? = try? TestSSHD()

    let scratch: URL

    init() throws {
        scratch = try makeScratchDirectory("keystore")
    }

    func pool(knownHosts: [String], keyStore: (any SSHKeyStore)?) -> SSHConnectionPool {
        var options = SSHConnectionPool.Options()
        options.knownHostsFiles = knownHosts
        options.agent = nil
        options.defaultKeyFiles = []
        options.keyStore = keyStore
        return SSHConnectionPool(options: options)
    }

    func authorize(_ line: String, on sshd: TestSSHD) throws {
        let file = sshd.directory.appendingPathComponent("authorized_keys")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    // MARK: Stores

    @Test func theSyncedAndDeviceKeysAreMadeOnce() throws {
        let store = InMemorySSHKeyStore()
        let synced = try store.syncedKey()
        #expect(try store.syncedKey() == synced)
        let device = try store.deviceKey()
        #expect(try store.deviceKey() == device)
        #expect(synced.storage == .iCloudKeychain && device.storage == .secureEnclave)
        #expect(synced.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(device.publicKey.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(store.keys().count == 2)
        #expect(store.signingKey(id: synced.id) != nil)
    }

    @Test func importingTheSameKeyTwiceKeepsOneCopy() throws {
        let store = InMemorySSHKeyStore()
        let material = SSHPrivateKeyMaterial.generateEd25519()
        let first = try store.importSynced(material, name: "id_ed25519")
        #expect(try store.importSynced(material, name: "again") == first)
        #expect(first.origin == .imported)
        #expect(store.keys().count == 1)
    }

    @Test func storesWithoutSyncOrEnclaveSaySo() {
        let store = InMemorySSHKeyStore(canSync: false, canUseSecureEnclave: false)
        #expect(throws: SSHKeyStoreError.syncUnavailable) { try store.syncedKey() }
        #expect(throws: SSHKeyStoreError.syncUnavailable) { try store.importSynced(.generateEd25519(), name: "x") }
        #expect(throws: SSHKeyStoreError.secureEnclaveUnavailable) { try store.deviceKey() }
    }

    @Test func authorizedKeysLinesNameTheirOrigin() throws {
        let store = InMemorySSHKeyStore(deviceName: "Iddo’s MacBook Pro")
        let synced = try store.syncedKey()
        let device = try store.deviceKey()
        #expect(synced.authorizedKeysLine == "\(synced.publicKey) relay (iCloud Keychain)")
        #expect(device.authorizedKeysComment == "relay (Iddo’s MacBook Pro)")
        #expect(synced.publicKeyBlob == String(synced.publicKey.split(separator: " ")[1]))
    }

    /// The Keychain store without an access group (an ad-hoc build): device
    /// keys in the login keychain, readable by a fresh store. Uses its own
    /// service name and removes what it made.
    @Test(.enabled(if: SecureEnclave.isAvailable))
    func theKeychainStoreKeepsDeviceKeys() throws {
        let service = "Relay SSH key test \(UUID().uuidString)"
        let store = KeychainSSHKeyStore(accessGroup: nil, service: service, deviceName: "Test Mac")
        #expect(!store.canSync)
        #expect(throws: SSHKeyStoreError.syncUnavailable) { try store.syncedKey() }
        let key = try store.deviceKey()
        defer { try? store.delete(id: key.id) }

        let reopened = KeychainSSHKeyStore(accessGroup: nil, service: service, deviceName: "Test Mac")
        #expect(reopened.keys() == [key])
        #expect(try reopened.deviceKey() == key)
        let signer = try #require(reopened.signingKey(id: key.id))
        #expect(String(openSSHPublicKey: signer.publicKey) == key.publicKey)

        try reopened.delete(id: key.id)
        #expect(store.keys().isEmpty)
    }

    // MARK: Signing in

    @Test(.enabled(if: sshd != nil))
    func storedKeysSignInToOpenSSH() async throws {
        let sshd = try #require(Self.sshd)
        let store = InMemorySSHKeyStore()
        let synced = try store.syncedKey()
        let device = try store.deviceKey()
        let pool = pool(knownHosts: [sshd.knownHostsPath], keyStore: store)
        func target(_ id: String) -> SSHTarget {
            SSHTarget(host: "127.0.0.1", port: sshd.port, username: NSUserName(), credentials: .storedKey(id: id))
        }

        // Not authorized yet: refused, and nothing else is offered.
        await #expect(throws: SSHClientError.authenticationFailed) { try await pool.verifyLogin(target: target(synced.id)) }

        try authorize(synced.authorizedKeysLine, on: sshd)
        try authorize(device.authorizedKeysLine, on: sshd)
        try await pool.verifyLogin(target: target(synced.id))
        try await pool.verifyLogin(target: target(device.id))
        let result = try await pool.exec(target: target(synced.id), command: "echo hi", stdin: Data(), timeout: .seconds(10))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hi\n")

        // A key this device doesn't have offers nothing.
        await #expect(throws: SSHClientError.authenticationFailed) { try await pool.verifyLogin(target: target("missing")) }
    }

    @Test(.enabled(if: sshd != nil && SecureEnclave.isAvailable))
    func aSecureEnclaveKeySignsInToOpenSSH() async throws {
        let sshd = try #require(Self.sshd)
        let enclaveKey = NIOSSHPrivateKey(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey())
        let publicKey = String(openSSHPublicKey: enclaveKey.publicKey)
        try authorize(publicKey + " relay (test)", on: sshd)

        final class EnclaveStore: SSHKeyStore, @unchecked Sendable {
            let key: NIOSSHPrivateKey
            init(key: NIOSSHPrivateKey) { self.key = key }
            var canSync: Bool { false }
            var canUseSecureEnclave: Bool { true }
            func keys() -> [SSHKeyInfo] { [] }
            func signingKey(id: String) -> NIOSSHPrivateKey? { id == "enclave" ? key : nil }
            func syncedKey() throws -> SSHKeyInfo { throw SSHKeyStoreError.syncUnavailable }
            func deviceKey() throws -> SSHKeyInfo { throw SSHKeyStoreError.secureEnclaveUnavailable }
            func importSynced(_ key: SSHPrivateKeyMaterial, name: String) throws -> SSHKeyInfo { throw SSHKeyStoreError.syncUnavailable }
            func delete(id: String) throws {}
        }
        let pool = pool(knownHosts: [sshd.knownHostsPath], keyStore: EnclaveStore(key: enclaveKey))
        try await pool.verifyLogin(target: SSHTarget(
            host: "127.0.0.1", port: sshd.port, username: NSUserName(), credentials: .storedKey(id: "enclave")))
    }

    // MARK: Host keys

    @Test func aTrustedNewHostKeyIsAcceptedNextTime() async throws {
        let server = try FakeSSHServer()
        defer { server.shutdown() }
        let trustFile = scratch.appendingPathComponent("relay_known_hosts").path
        let pool = pool(knownHosts: [trustFile], keyStore: nil)

        var presented = ""
        do {
            try await pool.verifyLogin(target: server.target)
            Issue.record("an unknown host key was accepted")
        } catch SSHClientError.hostKeyNotTrusted(let verdict, let key) {
            #expect(verdict == .unknown)
            presented = key
        }
        try KnownHosts.trust(host: "127.0.0.1", port: server.port, presentedKey: presented, in: trustFile)
        try await pool.verifyLogin(target: server.target)
        let attributes = try FileManager.default.attributesOfItem(atPath: trustFile)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func fingerprintsMatchSSHKeygen() throws {
        let key = SSHPrivateKeyMaterial.generateEd25519()
        let file = scratch.appendingPathComponent("fp.pub")
        try (key.publicKey + "\n").write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-l", "-E", "sha256", "-f", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.split(separator: " ")[1] == KnownHosts.fingerprint(ofPublicKey: key.publicKey).map { Substring($0) })
    }
}
