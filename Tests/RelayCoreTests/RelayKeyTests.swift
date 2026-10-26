import Foundation
import RelaySSH
import RelayTestSupport
import Testing
@testable import RelayCore

/// Relay keys end to end against the fake SSH server, which runs real
/// commands with its own HOME (so its `.ssh/authorized_keys` is a scratch
/// file — never the real one) and signs in keys listed there.
@Suite("Relay keys", .serialized)
struct RelayKeyTests {
    let scratch: URL
    let home: URL

    init() throws {
        scratch = try makeScratchDirectory("relaykeys")
        home = scratch.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var authorizedKeys: String {
        (try? String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8)) ?? ""
    }

    func server(acceptsKeys: Bool = true) throws -> FakeSSHServer {
        try FakeSSHServer(environment: ["HOME": home.path], acceptsKeys: acceptsKeys)
    }

    func pool(_ server: FakeSSHServer, store: any SSHKeyStore, knownHosts: [String]? = nil) throws -> SSHConnectionPool {
        var options = SSHConnectionPool.Options()
        options.knownHostsFiles = try knownHosts ?? [server.writeKnownHosts(in: scratch)]
        options.agent = nil
        options.defaultKeyFiles = []
        options.keyStore = store
        return SSHConnectionPool(options: options)
    }

    func host(_ server: FakeSSHServer, auth: SSHHostAuth = .password) -> SSHHost {
        SSHHost(alias: "fake", hostname: "127.0.0.1", port: server.port, user: NSUserName(), auth: auth)
    }

    // MARK: Setup

    @Test(arguments: [SSHKeyInfo.Storage.iCloudKeychain, .secureEnclave])
    func signingInOnceAddsTheKey(storage: SSHKeyInfo.Storage) async throws {
        let server = try server()
        defer { server.shutdown() }
        let store = InMemorySSHKeyStore()
        let setup = RelayKeySetup(store: store, pool: try pool(server, store: store), trustedHostsFile: nil)

        let outcome = try await setup.run(.init(host: host(server), password: FakeSSHServer.password, storage: storage))
        #expect(outcome.added)
        #expect(outcome.key.storage == storage)
        #expect(outcome.host.auth == .storedKey(id: outcome.key.id))
        #expect(authorizedKeys == outcome.key.authorizedKeysLine + "\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".ssh/authorized_keys").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        // Already there (say, a synced key another device added): no
        // sign-in needed, nothing written twice.
        let again = try await setup.run(.init(host: host(server), password: nil, storage: storage))
        #expect(!again.added)
        #expect(again.key == outcome.key)
        #expect(authorizedKeys == outcome.key.authorizedKeysLine + "\n")
    }

    @Test func existingKeysAreKeptAndAMissingNewlineIsAdded() async throws {
        let server = try server()
        defer { server.shutdown() }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "ssh-ed25519 AAAAexisting me@laptop".write(
            to: home.appendingPathComponent(".ssh/authorized_keys"), atomically: true, encoding: .utf8)
        let store = InMemorySSHKeyStore()
        let setup = RelayKeySetup(store: store, pool: try pool(server, store: store), trustedHostsFile: nil)
        let outcome = try await setup.run(.init(host: host(server), password: FakeSSHServer.password, storage: .iCloudKeychain))
        #expect(authorizedKeys == "ssh-ed25519 AAAAexisting me@laptop\n\(outcome.key.authorizedKeysLine)\n")
    }

    @Test func aRefusedSignInWritesNothing() async throws {
        let server = try server()
        defer { server.shutdown() }
        let store = InMemorySSHKeyStore()
        let setup = RelayKeySetup(store: store, pool: try pool(server, store: store), trustedHostsFile: nil)
        await #expect(throws: RelayKeySetup.Failure.signInFailed("Check the user and password.")) {
            try await setup.run(.init(host: host(server), password: "wrong", storage: .iCloudKeychain))
        }
        #expect(authorizedKeys.isEmpty)
    }

    @Test func aHostThatIgnoresAddedKeysIsReported() async throws {
        let server = try server(acceptsKeys: false)
        defer { server.shutdown() }
        let store = InMemorySSHKeyStore()
        let setup = RelayKeySetup(store: store, pool: try pool(server, store: store), trustedHostsFile: nil)
        await #expect(throws: RelayKeySetup.Failure.keyNotAccepted) {
            try await setup.run(.init(host: host(server), password: FakeSSHServer.password, storage: .secureEnclave))
        }
    }

    @Test func anUnknownHostIsTrustedOnRequest() async throws {
        let server = try server()
        defer { server.shutdown() }
        let store = InMemorySSHKeyStore()
        let trustFile = scratch.appendingPathComponent("relay_known_hosts").path
        let setup = RelayKeySetup(
            store: store, pool: try pool(server, store: store, knownHosts: [trustFile]), trustedHostsFile: trustFile)
        let request = RelayKeySetup.Request(host: host(server), password: FakeSSHServer.password, storage: .iCloudKeychain)
        var presented: String?
        do {
            _ = try await setup.run(request)
        } catch RelayKeySetup.Failure.unknownHostKey(let key) {
            presented = key
        }
        #expect(authorizedKeys.isEmpty)
        try setup.trust(host: request.host, presentedKey: try #require(presented))
        #expect(try await setup.run(request).added)
    }

    @Test func importingAKeyFileAsksForItsPassphrase() async throws {
        let server = try server()
        defer { server.shutdown() }
        let keyPath = scratch.appendingPathComponent("id_ed25519").path
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-a", "2", "-N", "open sesame", "-C", "me@laptop", "-f", keyPath]
        try keygen.run()
        keygen.waitUntilExit()
        let filePublicKey = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")

        let store = InMemorySSHKeyStore()
        let setup = RelayKeySetup(store: store, pool: try pool(server, store: store), trustedHostsFile: nil)
        var request = RelayKeySetup.Request(
            host: host(server), password: FakeSSHServer.password, storage: .iCloudKeychain, importKeyFile: keyPath)
        await #expect(throws: RelayKeySetup.Failure.needsPassphrase) { try await setup.run(request) }
        request.passphrase = "nope"
        await #expect(throws: RelayKeySetup.Failure.wrongPassphrase) { try await setup.run(request) }
        #expect(store.keys().isEmpty)

        request.passphrase = "open sesame"
        let outcome = try await setup.run(request)
        #expect(outcome.key.origin == .imported && outcome.key.name == "id_ed25519")
        #expect(outcome.key.publicKey == filePublicKey)
        #expect(authorizedKeys.contains(filePublicKey))

        // Another host with the same key file: the imported copy, no
        // passphrase asked.
        request.passphrase = nil
        let again = try await setup.run(request)
        #expect(again.key == outcome.key && !again.added)
        #expect(store.keys().count == 1)
    }

    @Test func proxiedHostsCantUseRelayKeys() async throws {
        let store = InMemorySSHKeyStore()
        let setup = RelayKeySetup(store: store, pool: SSHConnectionPool(), trustedHostsFile: nil)
        var proxied = SSHHost(alias: "p", hostname: "h", auth: .automatic)
        proxied.inheritedOptions = ["ProxyJump bastion"]
        await #expect(throws: RelayKeySetup.Failure.needsDirectConnection) {
            try await setup.run(.init(host: proxied, storage: .iCloudKeychain))
        }
    }

    // MARK: Keys on a host

    @Test func listsAndRemovesKeysOnTheHost() async throws {
        let server = try server()
        defer { server.shutdown() }
        let store = InMemorySSHKeyStore()
        let pool = try pool(server, store: store)
        let setup = RelayKeySetup(store: store, pool: pool, trustedHostsFile: nil)
        let synced = try await setup.run(.init(host: host(server), password: FakeSSHServer.password, storage: .iCloudKeychain))
        let device = try await setup.run(.init(host: host(server), password: FakeSSHServer.password, storage: .secureEnclave))

        func listed() async throws -> [SSHKeyInstaller.AuthorizedKey] {
            let result = try await pool.exec(
                target: server.target, command: "/bin/sh -s", stdin: Data(SSHKeyInstaller.listScript.utf8), timeout: .seconds(10))
            return SSHKeyInstaller.parseList(String(decoding: result.stdout, as: UTF8.self))
        }
        #expect(try await listed().map(\.publicKey) == [synced.key.publicKey, device.key.publicKey])
        #expect(try await listed().allSatisfy(\.isRelayKey))

        let remove = SSHKeyInstaller.removeScript(publicKeyBlob: synced.key.publicKeyBlob)
        let result = try await pool.exec(target: server.target, command: "/bin/sh -s", stdin: Data(remove.utf8), timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(try await listed().map(\.publicKey) == [device.key.publicKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".ssh/authorized_keys").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func parsesAuthorizedKeysLines() {
        let output = """
        RTERM_STATUS=ok
        RTERM_KEYS_BEGIN
        # a comment
        ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 me@laptop
        no-pty,command="echo hi there" ecdsa-sha2-nistp256 AAAAE2VjZHNh relay (Iddo’s Mac)

        garbage line
        """
        let keys = SSHKeyInstaller.parseList(output)
        #expect(keys == [
            .init(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5", comment: "me@laptop"),
            .init(publicKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNh", comment: "relay (Iddo’s Mac)"),
        ])
        #expect(!keys[0].isRelayKey && keys[1].isRelayKey)
        #expect(keys[1].publicKeyBlob == "AAAAE2VjZHNh")
    }

    // MARK: Routing

    func registry(_ hosts: [SSHHost]) -> SSHHostRegistry {
        let registry = SSHHostRegistry(
            configFile: scratch.appendingPathComponent("ssh_config-\(UUID().uuidString)"), userConfigPath: "/u", systemConfigPath: "/s")
        registry.setHosts(hosts)
        return registry
    }

    @Test func relayKeyHostsAlwaysUseTheBuiltInClient() throws {
        let store = InMemorySSHKeyStore()
        let key = try store.syncedKey()
        let registry = registry([
            SSHHost(alias: "keyed", hostname: "k.example", auth: .storedKey(id: key.id)),
            SSHHost(alias: "missing", hostname: "m.example", auth: .storedKey(id: "00000000-0000-0000-0000-000000000000")),
            SSHHost(alias: "plain", hostname: "p.example"),
        ])
        let router = BuiltInSSHRouter(
            registry: registry, keyStore: store, isEnabled: { false }, isTerminalEnabled: { false }, passwordLookup: { _ in nil })
        #expect(router.target(for: "keyed")?.credentials == .storedKey(id: key.id))
        #expect(router.terminalTarget(for: "keyed") != nil)
        #expect(router.target(for: "plain") == nil)
        #expect(router.isRequired("keyed") && !router.isRequired("plain"))

        // Failures never send it to the system ssh.
        router.noteFallback(alias: "keyed", error: .authenticationFailed)
        router.noteTerminalOpenFailure(alias: "keyed", error: SSHClientError.authenticationFailed)
        #expect(router.target(for: "keyed") != nil)

        #expect(router.setupProblem(for: "keyed") == nil)
        #expect(router.setupProblem(for: "missing") == "This host signs in with a Relay key that isn't on this device.")
        #expect(router.setupProblem(for: "plain") == nil)
    }

    @Test func aHostWhoseKeyIsElsewhereNeedsSetup() async throws {
        let registry = registry([SSHHost(alias: "elsewhere", hostname: "e.example", auth: .storedKey(id: "ABC-123"))])
        let router = BuiltInSSHRouter(
            registry: registry, keyStore: InMemorySSHKeyStore(), isEnabled: { true }, passwordLookup: { _ in nil })
        let runner = SSHCommandRunner(configFile: registry.configFile.path, builtIn: router)
        let result = try await runner.runScript(alias: "elsewhere", script: "true")
        #expect(result.exitCode == 255)
        #expect(result.stderr.hasPrefix(SSHCommandRunner.needsSetupPrefix))

        let provider = SSHTmuxRuntimeProvider(runner: runner, hostRegistry: registry, builtInSSH: router)
        let project = Project(name: "p", workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "elsewhere"),
                              pathInput: "/tmp", resolvedPath: "/tmp")
        await #expect(throws: RuntimeProviderError.hostNeedsSetup(
            workspace: "elsewhere", reason: "This host signs in with a Relay key that isn't on this device.")) {
            _ = try await provider.listSessions(for: project)
        }
    }

    @Test func aRefusedRelayKeyNeedsSetupInsteadOfFallingBack() async throws {
        let server = try server(acceptsKeys: false)
        defer { server.shutdown() }
        let store = InMemorySSHKeyStore()
        let key = try store.syncedKey()
        let registry = registry([host(server, auth: .storedKey(id: key.id))])
        let router = BuiltInSSHRouter(
            registry: registry, pool: try pool(server, store: store), keyStore: store,
            isEnabled: { false }, passwordLookup: { _ in nil })
        let runner = SSHCommandRunner(configFile: registry.configFile.path, builtIn: router)
        let result = try await runner.runScript(alias: "fake", script: "true")
        #expect(result.stderr == SSHCommandRunner.needsSetupPrefix + "The host didn't accept this device's Relay key.")
    }

    // MARK: Test Connection

    @Test func testConnectionUsesTheBuiltInClient() async throws {
        let server = try server()
        defer { server.shutdown() }
        let store = InMemorySSHKeyStore()
        let trustFile = scratch.appendingPathComponent("trust").path
        let pool = try pool(server, store: store, knownHosts: [trustFile])

        let first = await SSHConnectionTest.runBuiltIn(host: host(server), password: FakeSSHServer.password, pool: pool, keyStore: store)
        guard case .untrustedHostKey(let presented) = first else {
            Issue.record("expected an untrusted host key, got \(first)")
            return
        }
        try KnownHosts.trust(host: "127.0.0.1", port: server.port, presentedKey: presented, in: trustFile)
        let second = await SSHConnectionTest.runBuiltIn(host: host(server), password: FakeSSHServer.password, pool: pool, keyStore: store)
        #expect(second == .ok(tmuxVersion: second.tmuxVersion ?? "") || second == .noTmux)

        let wrong = await SSHConnectionTest.runBuiltIn(host: host(server), password: "nope", pool: pool, keyStore: store)
        #expect(wrong == .authenticationFailed("Check the user and password."))
        let elsewhere = await SSHConnectionTest.runBuiltIn(
            host: host(server, auth: .storedKey(id: "ABC")), password: nil, pool: pool, keyStore: store)
        #expect(elsewhere == .keyNotOnThisDevice)
    }

    // MARK: Transfers

    @Test func remotePathsSurviveAnyLoginShell() async throws {
        let server = try server()
        defer { server.shutdown() }
        let pool = try pool(server, store: InMemorySSHKeyStore())
        let name = #"we'ird $name "quoted" \back`tick`;|&.txt"#
        let path = scratch.appendingPathComponent(name).path
        let write = try await pool.exec(
            target: server.target, command: SSHTmuxRuntimeProvider.pathCommand(#"exec cat > "$p""#, path: path),
            input: .data(Data("payload".utf8)), timeout: .seconds(10))
        #expect(write.exitCode == 0)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "payload")
        let read = try await pool.exec(
            target: server.target, command: SSHTmuxRuntimeProvider.pathCommand(#"exec cat -- "$p""#, path: path),
            input: .data(Data()), timeout: .seconds(10))
        #expect(String(decoding: read.stdout, as: UTF8.self) == "payload")
    }

    @Test func streamsLargeFilesBothWays() async throws {
        let server = try server()
        defer { server.shutdown() }
        let pool = try pool(server, store: InMemorySSHKeyStore())
        let source = scratch.appendingPathComponent("big.bin")
        let bytes = try writeRandomFile(at: source, count: 5_000_000)
        let destination = scratch.appendingPathComponent("copy.bin").path
        let progress = Counter()
        let write = try await pool.exec(
            target: server.target, command: SSHTmuxRuntimeProvider.pathCommand(#"exec cat > "$p""#, path: destination),
            input: .file(source, onProgress: { progress.set($0) }), timeout: .seconds(60))
        #expect(write.exitCode == 0)
        #expect(progress.value == Int64(bytes.count))
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == bytes)

        let received = Counter()
        let read = try await pool.exec(
            target: server.target, command: SSHTmuxRuntimeProvider.pathCommand(#"exec cat -- "$p""#, path: destination),
            input: .data(Data()), timeout: .seconds(60), retainStdout: false, onStdout: { received.add(Int64($0.count)) })
        #expect(read.exitCode == 0 && read.stdout.isEmpty)
        #expect(received.value == Int64(bytes.count))
    }

    @Test func plansUploadsOfFoldersAndFiles() throws {
        let root = scratch.appendingPathComponent("drop")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder/inner"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("folder/a.txt"))
        try Data("bb".utf8).write(to: root.appendingPathComponent("folder/inner/b.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("folder/loop"), withDestinationURL: root.appendingPathComponent("folder"))
        try Data("ccc".utf8).write(to: root.appendingPathComponent("single.txt"))
        let plan = try SSHTmuxRuntimeProvider.uploadPlan(
            localPaths: [root.appendingPathComponent("folder").path, root.appendingPathComponent("single.txt").path],
            names: ["folder", "single.txt"])
        #expect(plan.directories == ["folder", "folder/inner"])
        #expect(plan.files.map(\.remote) == ["folder/a.txt", "folder/inner/b.txt", "single.txt"])
        #expect(plan.files.map(\.size) == [1, 2, 3])
    }
}

extension SSHConnectionTest.Outcome {
    var tmuxVersion: String? {
        if case .ok(let version) = self { return version }
        return nil
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int64 = 0
    var value: Int64 { lock.withLock { _value } }
    func set(_ value: Int64) { lock.withLock { _value = value } }
    func add(_ delta: Int64) { lock.withLock { _value += delta } }
}
