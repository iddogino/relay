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

    // MARK: Registry & jump hosts

    @Test func registryHoldsTheHostsAndTellsOfChanges() {
        let registry = SSHHostRegistry()
        let changes = Changes()
        registry.onHostsChanged = { changes.count += 1 }
        registry.setHosts([SSHHost(alias: "mini", hostname: "iddos-mac-mini")])
        #expect(registry.host(alias: "mini")?.hostname == "iddos-mac-mini")
        #expect(registry.host(alias: "other") == nil)
        #expect(changes.count == 1)
    }

    final class Changes: @unchecked Sendable { var count = 0 }

    @Test func aJumpHostIsAnotherHostsName() throws {
        try SSHHost(alias: "db", hostname: "db.internal", proxyJump: "bastion").validate()
        #expect(throws: SSHHost.ValidationError.proxyJump) {
            try SSHHost(alias: "db", hostname: "db.internal", proxyJump: "db").validate()
        }
        #expect(throws: SSHHost.ValidationError.proxyJump) {
            try SSHHost(alias: "db", hostname: "db.internal", proxyJump: "user@bastion:22").validate()
        }
        // Older state has no jump host.
        let old = try JSONDecoder().decode(SSHHost.self, from: Data(#"{"alias":"a","hostname":"h"}"#.utf8))
        #expect(old.proxyJump == nil)
        let round = try JSONDecoder().decode(
            SSHHost.self, from: JSONEncoder().encode(SSHHost(alias: "a", hostname: "h", proxyJump: "b")))
        #expect(round.proxyJump == "b")
    }

    @Test func importBringsJumpHostsAlong() {
        let configs = [
            "db": "hostname db.internal\nuser me\nport 22\nproxyjump admin@bastion:2222,inner",
            "bastion": "hostname bastion.example.com\nuser nobody\nport 22\nproxyjump edge",
            "edge": "hostname edge.example.com\nport 22",
            "inner": "hostname 10.1.1.1\nport 22",
        ]
        let hosts = SSHConfigImporter.importHosts(alias: "db", evaluate: { configs[$0] })
        func host(_ alias: String) -> SSHHost? { hosts.first { $0.alias == alias } }
        #expect(hosts.first?.alias == "db")
        #expect(Set(hosts.map(\.alias)) == ["db", "bastion", "edge", "inner"])
        // db ← inner ← bastion ← edge: each hop through the one before it.
        #expect(host("db")?.proxyJump == "inner")
        #expect(host("inner")?.proxyJump == "bastion")
        #expect(host("bastion")?.proxyJump == "edge")
        #expect(host("edge")?.proxyJump == nil)
        // The hop's own user/port win over its config.
        #expect(host("bastion")?.user == "admin")
        #expect(host("bastion")?.port == 2222)
        #expect(hosts.allSatisfy { (try? $0.validate()) != nil })

        // Jump hosts Relay already has are linked, not imported again.
        let linked = SSHConfigImporter.importHosts(alias: "db", existing: ["inner", "bastion"], evaluate: { configs[$0] })
        #expect(linked.map(\.alias) == ["db"])
        #expect(linked.first?.proxyJump == "inner")
    }

    @Test func aProxyCommandThatOnlyJumpsBecomesAJumpHost() {
        #expect(SSHConfigImporter.jumpHost(fromProxyCommand: "ssh -W %h:%p bastion") == "bastion")
        #expect(SSHConfigImporter.jumpHost(fromProxyCommand: "/usr/bin/ssh -q -W [%h]:%p admin@bastion") == "admin@bastion")
        #expect(SSHConfigImporter.jumpHost(fromProxyCommand: "exec ssh -W %h:%p bastion") == "bastion")
        #expect(SSHConfigImporter.jumpHost(fromProxyCommand: "ssh bastion nc %h %p") == nil)
        #expect(SSHConfigImporter.jumpHost(fromProxyCommand: "ssh -W %h:%p -o Foo=bar bastion") == nil)
        #expect(SSHConfigImporter.jumpHost(fromProxyCommand: "cloudflared access ssh --hostname %h") == nil)

        let hosts = SSHConfigImporter.importHosts(alias: "db", evaluate: { alias in
            alias == "db" ? "hostname db.internal\nproxycommand ssh -W %h:%p bastion" : "hostname b.example"
        })
        #expect(hosts.first?.proxyJump == "bastion")
        #expect(hosts.first?.inheritedOptions == [])
    }

    @Test func parsesJumpSpecs() {
        #expect(SSHConfigImporter.parseHop("bastion") == .init(spec: "bastion", user: nil, host: "bastion", port: nil))
        #expect(SSHConfigImporter.parseHop("me@b:2200") == .init(spec: "me@b:2200", user: "me", host: "b", port: 2200))
        #expect(SSHConfigImporter.parseHop("me@[::1]:2200") == .init(spec: "me@[::1]:2200", user: "me", host: "::1", port: 2200))
        #expect(SSHConfigImporter.parseHop("ssh://b") == nil)
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
