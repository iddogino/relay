import Foundation
import Testing
@testable import RelayCore

@Suite("Relay-owned SSH hosts")
struct SSHHostTests {
    // MARK: Validation

    @Test func acceptsOrdinaryHosts() throws {
        try SSHHost(alias: "iddo-gino-gputer", hostname: "iddo-gino-gputer", user: "iddogino",
                    auth: .keyFile(path: "~/.ssh/id_ed25519", certificatePath: nil)).validate()
        try SSHHost(alias: "box_2", hostname: "10.0.0.5", port: 2222).validate()
        try SSHHost(alias: "v6", hostname: "fe80::1").validate()
    }

    @Test func rejectsShapesThatCouldEscapeTheConfig() {
        let bad: [(SSHHost, SSHHost.ValidationError)] = [
            (SSHHost(alias: "-oProxyCommand=x", hostname: "h"), .alias),
            (SSHHost(alias: "web*", hostname: "h"), .alias),
            (SSHHost(alias: "two words", hostname: "h"), .alias),
            (SSHHost(alias: "a", hostname: "h\n  ProxyCommand evil"), .hostname),
            (SSHHost(alias: "a", hostname: "%h"), .hostname),
            (SSHHost(alias: "a", hostname: "h", port: 70000), .port),
            (SSHHost(alias: "a", hostname: "h", user: "me\"x"), .user),
            (SSHHost(alias: "a", hostname: "h", user: "%r"), .user),
            (SSHHost(alias: "a", hostname: "h", auth: .keyFile(path: "relative/key", certificatePath: nil)), .keyPath),
            (SSHHost(alias: "a", hostname: "h", auth: .keyFile(path: "/k\"\nProxyCommand x", certificatePath: nil)), .keyPath),
        ]
        for (host, expected) in bad {
            #expect(throws: expected) { try host.validate() }
        }
    }

    @Test func summaryElidesDefaults() {
        #expect(SSHHost(alias: "a", hostname: "h").summary == "h")
        #expect(SSHHost(alias: "a", hostname: "h", port: 22, user: "me").summary == "me@h")
        #expect(SSHHost(alias: "a", hostname: "h", port: 2222, user: "me").summary == "me@h:2222")
    }

    // MARK: Rendering

    @Test func rendersRelayHostsBeforeTheUserAndSystemConfigs() {
        let text = SSHHostRegistry.render(
            hosts: [
                SSHHost(alias: "gputer", hostname: "iddo-gino-gputer", user: "iddogino",
                        auth: .keyFile(path: "~/.ssh/id_ed25519", certificatePath: "~/.ssh/id_ed25519-cert.pub")),
                SSHHost(alias: "box", hostname: "10.0.0.5", port: 2222),
                SSHHost(alias: "pw", hostname: "pw.example", auth: .password),
            ],
            userConfigPath: "/Users/me/.ssh/config",
            systemConfigPath: "/etc/ssh/ssh_config")
        let lines = text.split(separator: "\n").map(String.init)
        let expected = [
            "Host gputer",
            "  HostName iddo-gino-gputer",
            "  User iddogino",
            "  IdentityFile \"~/.ssh/id_ed25519\"",
            "  CertificateFile \"~/.ssh/id_ed25519-cert.pub\"",
            "  AddKeysToAgent yes",
            "  UseKeychain yes",
            "Host box",
            "  HostName 10.0.0.5",
            "  Port 2222",
            "Host pw",
            "  HostName pw.example",
            "  PreferredAuthentications keyboard-interactive,password",
            "  PubkeyAuthentication no",
            "Match all",
            "Include \"/Users/me/.ssh/config\"",
            "Include \"/etc/ssh/ssh_config\"",
        ]
        #expect(lines.filter { !$0.hasPrefix("#") } == expected)
    }

    @Test func skipsInvalidHostsAndEscapesTokens() {
        let text = SSHHostRegistry.render(
            hosts: [
                SSHHost(alias: "evil", hostname: "h\nProxyCommand x"),
                SSHHost(alias: "pct", hostname: "h", auth: .keyFile(path: "/keys/100%/id", certificatePath: nil)),
            ],
            userConfigPath: "/u", systemConfigPath: "/s")
        #expect(!text.contains("ProxyCommand"))
        #expect(text.contains("# Skipped evil"))
        #expect(text.contains("IdentityFile \"/keys/100%%/id\""))
    }

    @Test func registryWritesAPrivateConfigFileImmediately() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-reg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ssh_config")
        let registry = SSHHostRegistry(configFile: file, userConfigPath: "/u", systemConfigPath: "/s")
        let initial = try String(contentsOf: file, encoding: .utf8)
        #expect(initial.contains("Include \"/u\""))
        #expect(!initial.contains("Host "))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        registry.setHosts([SSHHost(alias: "mini", hostname: "iddos-mac-mini")])
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Host mini"))
        #expect(registry.host(alias: "mini")?.hostname == "iddos-mac-mini")
    }

    // MARK: Import (ssh -G)

    @Test func importsExplicitKeyAndUser() {
        let dump = """
        user iddogino
        hostname iddo-gino-gputer
        port 22
        identitiesonly no
        identityfile ~/.ssh/id_ed25519
        forwardagent no
        proxyjump none
        """
        let host = SSHConfigImporter.host(alias: "iddo-gino-gputer", effectiveConfig: dump)
        #expect(host == SSHHost(alias: "iddo-gino-gputer", hostname: "iddo-gino-gputer", port: nil, user: "iddogino",
                                auth: .keyFile(path: "~/.ssh/id_ed25519", certificatePath: nil)))
    }

    @Test func defaultKeyListMeansAutomatic() {
        let dump = """
        user me
        hostname example.com
        port 2200
        identityfile ~/.ssh/id_rsa
        identityfile ~/.ssh/id_ecdsa
        identityfile ~/.ssh/id_ecdsa_sk
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/id_ed25519_sk
        """
        let host = SSHConfigImporter.host(alias: "ex", effectiveConfig: dump)
        #expect(host.auth == .automatic)
        #expect(host.port == 2200)
    }

    @Test func recordsWhatRelayDoesNotModel() {
        let dump = """
        user default
        hostname 127.0.0.1
        port 32222
        identityfile ~/.orbstack/ssh/id_ed25519
        proxycommand '/Applications/OrbStack.app/Helper' ssh-proxy-fdpass 501
        localforward 8080 [localhost]:80
        forwardagent yes
        """
        let host = SSHConfigImporter.host(alias: "orb", effectiveConfig: dump)
        #expect(host.inheritedOptions == [
            "ProxyCommand '/Applications/OrbStack.app/Helper' ssh-proxy-fdpass 501",
            "LocalForward 8080 [localhost]:80",
            "ForwardAgent yes",
        ])
        #expect(host.hostname == "127.0.0.1")
    }

    @Test func importDropsFieldsRelayCannotStore() {
        let dump = """
        user some user
        hostname bad host
        identityfile relative/key
        """
        let host = SSHConfigImporter.host(alias: "x", effectiveConfig: dump)
        #expect(host.hostname == "x")
        #expect(host.user == nil)
        #expect(host.auth == .automatic)
        #expect((try? host.validate()) != nil)
    }

    // MARK: Connection test classification

    @Test func classifiesTestOutcomes() {
        #expect(SSHConnectionTest.outcome(exitCode: 0, stdout: "RTERM_STATUS=ok\nRTERM_TMUX_VERSION=tmux 3.4\n", stderr: "")
                == .ok(tmuxVersion: "tmux 3.4"))
        #expect(SSHConnectionTest.outcome(exitCode: 21, stdout: "RTERM_STATUS=no_tmux\n", stderr: "") == .noTmux)
        if case .unknownHostKey = SSHConnectionTest.outcome(
            exitCode: 255, stdout: "",
            stderr: "No ED25519 host key is known for box and you have requested strict checking.\nHost key verification failed.") {
        } else { Issue.record("expected unknownHostKey") }
        if case .changedHostKey = SSHConnectionTest.outcome(
            exitCode: 255, stdout: "",
            stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.") {
        } else { Issue.record("expected changedHostKey") }
        if case .authenticationFailed = SSHConnectionTest.outcome(
            exitCode: 255, stdout: "", stderr: "me@box: Permission denied (publickey).") {
        } else { Issue.record("expected authenticationFailed") }
        if case .unreachable = SSHConnectionTest.outcome(
            exitCode: 255, stdout: "", stderr: "ssh: Could not resolve hostname nope: nodename nor servname provided") {
        } else { Issue.record("expected unreachable") }
    }

    // MARK: Persistence

    @Test func stateWithoutHostsDecodesAsUnmigrated() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{\"projects\": []}".utf8))
        #expect(state.hosts == nil)
    }

    @Test func hostsRoundTripAndBadRecordsAreDroppedNotFatal() throws {
        let hosts = [
            SSHHost(alias: "a", hostname: "a.example", auth: .keyFile(path: "~/.ssh/k", certificatePath: nil)),
            SSHHost(alias: "b", hostname: "b.example", port: 2222, auth: .password),
        ]
        let data = try JSONEncoder().encode(PersistedState(hosts: hosts))
        #expect(try JSONDecoder().decode(PersistedState.self, from: data).hosts == hosts)

        let mixed = #"{"projects": [], "hosts": [{"alias": "ok", "hostname": "h"}, {"nonsense": 1}]}"#
        let decoded = try JSONDecoder().decode(PersistedState.self, from: Data(mixed.utf8))
        #expect(decoded.hosts == [SSHHost(alias: "ok", hostname: "h")])
    }
}
