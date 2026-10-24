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

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }
}
