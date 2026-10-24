import Foundation
import RelaySSH
import Testing
@testable import RelayCore

@Suite("Built-in SSH routing")
struct BuiltInSSHRouterTests {
    @Test func takesHostsRelayFullyDescribes() {
        let key = SSHHost(alias: "gputer", hostname: "iddo-gino-gputer", user: "iddogino",
                          auth: .keyFile(path: "~/.ssh/id_ed25519", certificatePath: nil))
        #expect(BuiltInSSHRouter.target(for: key, password: { nil })
                == SSHTarget(host: "iddo-gino-gputer", port: 22, username: "iddogino",
                             credentials: .keyFile(path: "~/.ssh/id_ed25519")))

        let auto = SSHHost(alias: "box", hostname: "10.0.0.5", port: 2222)
        #expect(BuiltInSSHRouter.target(for: auto, password: { nil })
                == SSHTarget(host: "10.0.0.5", port: 2222, username: NSUserName(), credentials: .automatic))

        let pw = SSHHost(alias: "pw", hostname: "pw.example", auth: .password)
        #expect(BuiltInSSHRouter.target(for: pw, password: { "s3cret" })?.credentials == .password("s3cret"))
    }

    @Test func leavesTheRestToTheSystemSSH() {
        var proxied = SSHHost(alias: "orb", hostname: "127.0.0.1")
        proxied.inheritedOptions = ["ProxyCommand /x"]
        #expect(BuiltInSSHRouter.target(for: proxied, password: { nil }) == nil)

        let cert = SSHHost(alias: "c", hostname: "h",
                           auth: .keyFile(path: "~/.ssh/k", certificatePath: "~/.ssh/k-cert.pub"))
        #expect(BuiltInSSHRouter.target(for: cert, password: { nil }) == nil)

        let noPassword = SSHHost(alias: "pw", hostname: "h", auth: .password)
        #expect(BuiltInSSHRouter.target(for: noPassword, password: { nil }) == nil)
    }

    @Test func terminalsAreOffUnlessSwitchedOn() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = SSHHostRegistry(configFile: dir.appendingPathComponent("ssh_config"), userConfigPath: "/u", systemConfigPath: "/s")
        registry.setHosts([SSHHost(alias: "box", hostname: "box.example")])
        let router = BuiltInSSHRouter(registry: registry, isEnabled: { true }, passwordLookup: { _ in nil })
        #expect(router.target(for: "box") != nil)
        #expect(router.terminalTarget(for: "box") == nil)
    }

    @Test func respectsTheSwitchAndFallbacks() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = SSHHostRegistry(configFile: dir.appendingPathComponent("ssh_config"), userConfigPath: "/u", systemConfigPath: "/s")
        registry.setHosts([SSHHost(alias: "box", hostname: "box.example")])
        let enabled = Flag()
        let router = BuiltInSSHRouter(registry: registry, isEnabled: { enabled.value }, passwordLookup: { _ in nil })

        #expect(router.target(for: "box") == nil)
        enabled.value = true
        #expect(router.target(for: "box") != nil)
        #expect(router.target(for: "unknown") == nil)

        router.noteFallback(alias: "box", error: .authenticationFailed)
        #expect(router.target(for: "box") == nil)
        router.hostsChanged()
        #expect(router.target(for: "box") != nil)
    }

    @Test func terminalsHaveTheirOwnSwitchAndFallBackOnRecurringFailures() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = SSHHostRegistry(configFile: dir.appendingPathComponent("ssh_config"), userConfigPath: "/u", systemConfigPath: "/s")
        registry.setHosts([SSHHost(alias: "box", hostname: "box.example")])
        let commands = Flag()
        let terminals = Flag()
        let router = BuiltInSSHRouter(registry: registry, isEnabled: { commands.value },
                                      isTerminalEnabled: { terminals.value }, passwordLookup: { _ in nil })

        commands.value = true
        #expect(router.terminalTarget(for: "box") == nil)
        commands.value = false
        terminals.value = true
        #expect(router.terminalTarget(for: "box") != nil)
        #expect(router.target(for: "box") == nil)

        // A host that's down is down for ssh too: no fallback.
        router.noteTerminalOpenFailure(alias: "box", error: SSHClientError.unreachable("refused"))
        #expect(router.terminalTarget(for: "box") != nil)
        router.noteTerminalOpenFailure(alias: "box", error: CancellationError())
        #expect(router.terminalTarget(for: "box") != nil)
        // One that refuses us would refuse again: the system ssh takes it.
        router.noteTerminalOpenFailure(alias: "box", error: SSHClientError.authenticationFailed)
        #expect(router.terminalTarget(for: "box") == nil)
        router.hostsChanged()
        router.noteTerminalOpenFailure(alias: "box", error: SSHClientError.channelFailed("refused a terminal"))
        #expect(router.terminalTarget(for: "box") == nil)
    }

    @Test func fallbacksExpireAndPasswordsAreLookedUpOnce() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = SSHHostRegistry(configFile: dir.appendingPathComponent("ssh_config"), userConfigPath: "/u", systemConfigPath: "/s")
        registry.setHosts([SSHHost(alias: "pw", hostname: "pw.example", auth: .password)])
        let lookups = Counter()
        let router = BuiltInSSHRouter(
            registry: registry, isEnabled: { true }, isTerminalEnabled: { true },
            passwordLookup: { _ in lookups.increment(); return "s3cret" },
            fallbackCooldown: .milliseconds(100))

        #expect(router.terminalTarget(for: "pw")?.credentials == .password("s3cret"))
        #expect(router.target(for: "pw")?.credentials == .password("s3cret"))
        #expect(lookups.value == 1)

        router.noteTerminalOpenFailure(alias: "pw", error: SSHClientError.authenticationFailed)
        #expect(router.terminalTarget(for: "pw") == nil)
        try await Task.sleep(for: .milliseconds(150))
        // The cooldown is over: the built-in client gets another chance.
        #expect(router.terminalTarget(for: "pw") != nil)

        // Changed hosts or passwords are looked up afresh.
        router.hostsChanged()
        _ = router.target(for: "pw")
        #expect(lookups.value == 2)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test func aBuiltInTerminalRunsWhatSSHWouldRun() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = SSHHostRegistry(configFile: dir.appendingPathComponent("ssh_config"), userConfigPath: "/u", systemConfigPath: "/s")
        var proxied = SSHHost(alias: "orb", hostname: "127.0.0.1")
        proxied.inheritedOptions = ["ProxyCommand /x"]
        registry.setHosts([SSHHost(alias: "box", hostname: "box.example", port: 2200, user: "me"), proxied])
        let terminals = Flag()
        let router = BuiltInSSHRouter(registry: registry, isEnabled: { false },
                                      isTerminalEnabled: { terminals.value }, passwordLookup: { _ in nil })
        let provider = SSHTmuxRuntimeProvider(hostRegistry: registry, builtInSSH: router)
        let project = Project(name: "P", workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "box"),
                              pathInput: "~/code", resolvedPath: "/home/me/code")
        let session = RemoteSession(id: SessionID(), projectID: project.id, displayName: "work",
                                    createdAt: Date(), backendID: "rterm-abc123")

        #expect(try await provider.makeTerminalLaunch(for: session, project: project).builtIn == nil)

        terminals.value = true
        let launch = try await provider.makeTerminalLaunch(for: session, project: project)
        let builtIn = try #require(launch.builtIn)
        #expect(builtIn.target == SSHTarget(host: "box.example", port: 2200, username: "me", credentials: .automatic))
        // ssh joins the arguments after the alias into the remote command line.
        let alias = try #require(launch.arguments.firstIndex(of: "box"))
        #expect(builtIn.command == launch.arguments[(alias + 1)...].joined(separator: " "))
        #expect(builtIn.command.hasPrefix("sh -c '"))
        #expect(builtIn.command.contains("attach-session -t rterm-abc123"))

        // Hosts the client can't handle keep the system ssh.
        let other = Project(name: "Q", workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "orb"),
                            pathInput: "~", resolvedPath: "/root")
        #expect(try await provider.makeTerminalLaunch(for: session, project: other).builtIn == nil)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }
}
