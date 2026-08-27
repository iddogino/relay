import Foundation
import Testing
@testable import RelayCore

@Suite("SSH config discovery")
struct SSHConfigDiscoveryTests {
    private func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func singleHostAlias() throws {
        try withTempDir { dir in
            let config = dir.appendingPathComponent("config")
            try write("Host macmini\n  HostName example.com\n", to: config)
            #expect(SSHConfigDiscovery.discoverAliases(configPath: config.path) == ["macmini"])
        }
    }

    @Test func multipleAliasesOnOneLine() throws {
        try withTempDir { dir in
            let config = dir.appendingPathComponent("config")
            try write("Host ubuntu gpu backup\n  HostName 10.0.0.25\n", to: config)
            #expect(SSHConfigDiscovery.discoverAliases(configPath: config.path) == ["ubuntu", "gpu", "backup"])
        }
    }

    @Test func wildcardAndNegatedAliasesSkipped() throws {
        try withTempDir { dir in
            let config = dir.appendingPathComponent("config")
            try write(
                """
                Host *
                  ServerAliveInterval 30
                Host *.internal
                  User svc
                Host !bastion real-host foo?
                  User me
                """,
                to: config
            )
            #expect(SSHConfigDiscovery.discoverAliases(configPath: config.path) == ["real-host"])
        }
    }

    @Test func duplicatesDeduplicatedPreservingOrder() throws {
        try withTempDir { dir in
            let config = dir.appendingPathComponent("config")
            try write(
                """
                Host alpha
                Host beta
                Host alpha
                  Port 2222
                """,
                to: config
            )
            #expect(SSHConfigDiscovery.discoverAliases(configPath: config.path) == ["alpha", "beta"])
        }
    }

    @Test func includeRecursion() throws {
        try withTempDir { dir in
            let config = dir.appendingPathComponent("config")
            let extra = dir.appendingPathComponent("extra.conf")
            let nested = dir.appendingPathComponent("nested.conf")
            try write("Host top\nInclude \(extra.path)\n", to: config)
            try write("Host middle\nInclude \(nested.path)\n", to: extra)
            try write("Host bottom\n", to: nested)
            #expect(SSHConfigDiscovery.discoverAliases(configPath: config.path) == ["top", "middle", "bottom"])
        }
    }

    @Test func includeGlob() throws {
        try withTempDir { dir in
            let config = dir.appendingPathComponent("config")
            try write("Host a1\n", to: dir.appendingPathComponent("one.conf"))
            try write("Host a2\n", to: dir.appendingPathComponent("two.conf"))
            try write("Include \(dir.path)/*.conf\nHost main\n", to: config)
            let aliases = SSHConfigDiscovery.discoverAliases(configPath: config.path)
            #expect(aliases.contains("a1"))
            #expect(aliases.contains("a2"))
            #expect(aliases.contains("main"))
        }
    }

    @Test func includeCycleDoesNotHang() throws {
        try withTempDir { dir in
            let a = dir.appendingPathComponent("a.conf")
            let b = dir.appendingPathComponent("b.conf")
            try write("Host from-a\nInclude \(b.path)\n", to: a)
            try write("Host from-b\nInclude \(a.path)\n", to: b)
            #expect(SSHConfigDiscovery.discoverAliases(configPath: a.path) == ["from-a", "from-b"])
        }
    }

    @Test func missingConfigReturnsEmpty() {
        #expect(SSHConfigDiscovery.discoverAliases(configPath: "/nonexistent/path/config").isEmpty)
    }

    @Test func commentsAndBlankLinesIgnored() throws {
        try withTempDir { dir in
            let config = dir.appendingPathComponent("config")
            try write(
                """
                # a comment

                Host real
                # Host commented-out
                """,
                to: config
            )
            #expect(SSHConfigDiscovery.discoverAliases(configPath: config.path) == ["real"])
        }
    }

    @Test func equalsSeparatorAndQuotes() throws {
        try withTempDir { dir in
            let config = dir.appendingPathComponent("config")
            try write("Host=eqhost\nHost \"quoted host\"\n", to: config)
            let aliases = SSHConfigDiscovery.discoverAliases(configPath: config.path)
            #expect(aliases.contains("eqhost"))
            #expect(aliases.contains("quoted host"))
        }
    }
}
