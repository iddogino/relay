import Foundation
import RelaySSH
import Testing
@testable import RelayCore

@Suite("Built-in SSH routing")
struct BuiltInSSHRouterTests {
    private static func connection(
        _ host: SSHHost, hosts: [SSHHost] = [], password: String? = nil, storedKeys: Set<String> = []
    ) -> BuiltInSSHRouter.Connection {
        BuiltInSSHRouter.connection(
            for: host, hosts: { alias in hosts.first { $0.alias == alias } }, password: { _ in password },
            hasStoredKey: { storedKeys.contains($0) })
    }

    private static func reason(_ connection: BuiltInSSHRouter.Connection) -> String? {
        if case .needsSetup(let reason) = connection { return reason }
        return nil
    }

    /// A key file that exists, for hosts that sign in with one.
    private static let keyFile: String = {
        let path = NSTemporaryDirectory() + "relay-router-key-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: path, contents: Data("key".utf8))
        return path
    }()

    @Test func resolvesEveryKindOfSignIn() {
        let key = SSHHost(alias: "gputer", hostname: "iddo-gino-gputer", user: "iddogino",
                          auth: .keyFile(path: Self.keyFile, certificatePath: nil))
        #expect(Self.connection(key) == .ready(SSHTarget(
            host: "iddo-gino-gputer", port: 22, username: "iddogino", credentials: .keyFile(path: Self.keyFile))))

        let cert = SSHHost(alias: "c", hostname: "h", auth: .keyFile(path: Self.keyFile, certificatePath: "/x/k-cert.pub"))
        #expect(Self.connection(cert) == .ready(SSHTarget(
            host: "h", port: 22, username: NSUserName(),
            credentials: .keyFile(path: Self.keyFile, certificatePath: "/x/k-cert.pub"))))

        let auto = SSHHost(alias: "box", hostname: "10.0.0.5", port: 2222)
        #expect(Self.connection(auto) == .ready(SSHTarget(host: "10.0.0.5", port: 2222, username: NSUserName(), credentials: .automatic)))

        let pw = SSHHost(alias: "pw", hostname: "pw.example", auth: .password)
        #expect(Self.connection(pw, password: "s3cret") == .ready(SSHTarget(
            host: "pw.example", port: 22, username: NSUserName(), credentials: .password("s3cret"))))

        let relay = SSHHost(alias: "r", hostname: "r.example", auth: .storedKey(id: "K1"))
        #expect(Self.connection(relay, storedKeys: ["K1"]) == .ready(SSHTarget(
            host: "r.example", port: 22, username: NSUserName(), credentials: .storedKey(id: "K1"))))
    }

    @Test func saysWhatAHostNeedsWhenItCantConnect() throws {
        let noPassword = SSHHost(alias: "pw", hostname: "h", auth: .password)
        #expect(try #require(Self.reason(Self.connection(noPassword))).contains("No password"))

        let elsewhere = SSHHost(alias: "r", hostname: "h", auth: .storedKey(id: "K1"))
        #expect(try #require(Self.reason(Self.connection(elsewhere))).contains("isn\u{2019}t on this device"))

        let missingKey = SSHHost(alias: "k", hostname: "h", auth: .keyFile(path: "/nonexistent/key", certificatePath: nil))
        #expect(try #require(Self.reason(Self.connection(missingKey))).contains("/nonexistent/key"))

        var proxied = SSHHost(alias: "orb", hostname: "127.0.0.1")
        proxied.inheritedOptions = ["ProxyCommand /x"]
        #expect(try #require(Self.reason(Self.connection(proxied))).contains("ProxyCommand"))

        // Settings Relay doesn't use (forwards…) don't stop it connecting.
        var forwards = SSHHost(alias: "f", hostname: "h")
        forwards.inheritedOptions = ["LocalForward 8080 [localhost]:80", "ForwardAgent yes"]
        #expect(Self.reason(Self.connection(forwards)) == nil)
    }

    @Test func connectsThroughJumpHostsInOrder() throws {
        let edge = SSHHost(alias: "edge", hostname: "edge.example", user: "e")
        let bastion = SSHHost(alias: "bastion", hostname: "bastion.internal", port: 2222, auth: .storedKey(id: "K1"), proxyJump: "edge")
        let target = SSHHost(alias: "db", hostname: "db.internal", proxyJump: "bastion")
        let connection = Self.connection(target, hosts: [edge, bastion], storedKeys: ["K1"])
        guard case .ready(let resolved) = connection else { Issue.record("\(connection)"); return }
        #expect(resolved.host == "db.internal")
        // Reached directly first, then each next hop through the previous.
        #expect(resolved.jumps == [
            SSHTarget(host: "edge.example", port: 22, username: "e", credentials: .automatic),
            SSHTarget(host: "bastion.internal", port: 2222, username: NSUserName(), credentials: .storedKey(id: "K1")),
        ])
        #expect(resolved.jumps.allSatisfy { $0.jumps.isEmpty })
    }

    @Test func aJumpHostsProblemIsTheTargetsProblem() throws {
        let bastion = SSHHost(alias: "bastion", hostname: "b", auth: .password)
        let target = SSHHost(alias: "db", hostname: "d", proxyJump: "bastion")
        #expect(try #require(Self.reason(Self.connection(target, hosts: [bastion]))).contains("\u{201C}bastion\u{201D}"))

        let orphan = SSHHost(alias: "db", hostname: "d", proxyJump: "gone")
        #expect(try #require(Self.reason(Self.connection(orphan))).contains("gone"))

        let a = SSHHost(alias: "a", hostname: "a", proxyJump: "b")
        let b = SSHHost(alias: "b", hostname: "b", proxyJump: "a")
        #expect(try #require(Self.reason(Self.connection(a, hosts: [a, b]))).contains("lead back"))
    }

    @Test func looksUpPasswordsOnceUntilHostsChange() {
        let registry = SSHHostRegistry(hosts: [SSHHost(alias: "pw", hostname: "pw.example", auth: .password)])
        let lookups = Counter()
        let router = BuiltInSSHRouter(registry: registry, passwordLookup: { _ in lookups.increment(); return "s3cret" })
        #expect(router.setupProblem(for: "pw") == nil)
        #expect(router.setupProblem(for: "pw") == nil)
        #expect(lookups.value == 1)
        router.hostsChanged()
        _ = router.connection(for: "pw")
        #expect(lookups.value == 2)
        #expect(router.setupProblem(for: "unknown") != nil)
    }

    @Test func authFailuresNeedSetupAndSayWhichSignIn() {
        let reasons = [SSHHostAuth.storedKey(id: "K"), .password, .keyFile(path: "/k", certificatePath: nil), .automatic].map {
            BuiltInSSHRouter.setupReason(for: .authenticationFailed, host: SSHHost(alias: "h", hostname: "h", auth: $0))
        }
        #expect(Set(reasons.compactMap { $0 }).count == 4)
        #expect(BuiltInSSHRouter.setupReason(for: .hostKeyNotTrusted(.unknown, presented: "k"), host: nil) != nil)
        #expect(BuiltInSSHRouter.setupReason(for: .unreachable("refused"), host: nil) == nil)
        #expect(BuiltInSSHRouter.setupReason(for: .connectionLost, host: nil) == nil)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test func aTerminalRunsTheAttachOverTheBuiltInClient() async throws {
        let registry = SSHHostRegistry()
        var proxied = SSHHost(alias: "orb", hostname: "127.0.0.1")
        proxied.inheritedOptions = ["ProxyCommand /x"]
        registry.setHosts([SSHHost(alias: "box", hostname: "box.example", port: 2200, user: "me"), proxied])
        let router = BuiltInSSHRouter(registry: registry, passwordLookup: { _ in nil })
        let provider = SSHTmuxRuntimeProvider(hostRegistry: registry, builtInSSH: router)
        let project = Project(name: "P", workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "box"),
                              pathInput: "~/code", resolvedPath: "/home/me/code")
        let session = RemoteSession(id: SessionID(), projectID: project.id, displayName: "work",
                                    createdAt: Date(), backendID: "rterm-abc123")

        let launch = try await provider.makeTerminalLaunch(for: session, project: project)
        #expect(launch.target == SSHTarget(host: "box.example", port: 2200, username: "me", credentials: .automatic))
        #expect(launch.command.hasPrefix("sh -c '"))
        #expect(launch.command.contains("attach-session -t rterm-abc123"))

        // A host Relay can't connect to fails with the reason.
        let other = Project(name: "Q", workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "orb"),
                            pathInput: "~", resolvedPath: "/root")
        await #expect(throws: RuntimeProviderError.self) {
            _ = try await provider.makeTerminalLaunch(for: session, project: other)
        }
    }
}
