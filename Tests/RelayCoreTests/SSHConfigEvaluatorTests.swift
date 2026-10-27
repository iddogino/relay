import Foundation
import RelayTestSupport
import Testing
@testable import RelayCore

/// The in-app ssh_config evaluator, checked against the real thing: every
/// differential case writes a config to a temp folder and compares the
/// evaluator with `ssh -G -F <config> <alias>` key by key.
///
/// The evaluator follows OpenSSH 10, and so must the ssh it's compared
/// with: older versions differ (no expansion in User, a final pass for any
/// `Match final`, more default keys…). Those comparisons are skipped with
/// an older ssh; CI installs OpenSSH 10 and points `RELAY_TEST_SSH` at it.
@Suite("SSH config evaluator")
struct SSHConfigEvaluatorTests {
    /// What the comparison covers (what Relay reads from a config).
    static let comparedKeys = [
        "host", "hostname", "user", "port", "identityfile", "certificatefile", "proxyjump", "proxycommand",
        "localforward", "remoteforward", "dynamicforward", "forwardagent",
    ]

    static let sshPath = ProcessInfo.processInfo.environment["RELAY_TEST_SSH"] ?? "/usr/bin/ssh"

    /// `ssh -V`, e.g. "OpenSSH_10.3p1, LibreSSL 3.3.6".
    static let sshVersion: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = ["-V"]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// Whether `sshPath` is OpenSSH 10 or later — what the comparisons need.
    static let comparesWithSSH: Bool = {
        guard let match = sshVersion.firstMatch(of: /^OpenSSH_(\d+)\./), let major = Int(match.1) else { return false }
        return major >= 10
    }()

    @Test func theComparisonSSHIsOpenSSH10() {
        // CI requires it, so the comparisons can't quietly stop running.
        if ProcessInfo.processInfo.environment["RELAY_TEST_REQUIRE_OPENSSH10"] == "1" {
            #expect(Self.comparesWithSSH, "\(Self.sshPath): \(Self.sshVersion)")
        }
    }

    // MARK: Harness

    final class Fixture {
        let directory: URL
        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("relay-sshcfg-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        var path: String { directory.path }

        @discardableResult
        func write(_ name: String, _ text: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
    }

    /// `ssh -G` for `alias`, or nil when ssh rejects the config.
    static func sshG(config: String, alias: String) throws -> [String: [String]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = ["-G", "-F", config, "--", alias]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        // Thousands of runs: don't wait for the pipes to be deallocated.
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            values[String(line[..<space]), default: []].append(String(line[line.index(after: space)...]))
        }
        return values
    }

    static func render(_ values: [String: [String]]) -> String {
        values.flatMap { key, list in list.map { "\(key) \($0)" } }.joined(separator: "\n") + "\n"
    }

    static func evaluate(config: String, alias: String) -> [String: [String]] {
        SSHConfigEvaluator.evaluate(alias: alias, configPath: config, environment: .local())
    }

    static func differences(_ ours: [String: [String]], _ ssh: [String: [String]]) -> [String] {
        comparedKeys.compactMap { key in
            let a = ours[key] ?? [], b = ssh[key] ?? []
            return a == b ? nil : "\(key): ours \(a) vs ssh \(b)"
        }
    }

    /// Asserts the evaluator agrees with `ssh -G` for every alias.
    static func expectAgreement(
        _ config: String, aliases: [String], fixture: Fixture? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let fixture = try fixture ?? Fixture()
        let path = try fixture.write("config", config)
        for alias in aliases {
            guard let ssh = try sshG(config: path, alias: alias) else {
                Issue.record("ssh -G rejected the config for \(alias):\n\(config)", sourceLocation: sourceLocation)
                continue
            }
            let diffs = differences(evaluate(config: path, alias: alias), ssh)
            #expect(diffs.isEmpty, "\(alias): \(diffs.joined(separator: "; "))\n--- config ---\n\(config)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Differential cases

    @Test(.enabled(if: comparesWithSSH)) func defaults() throws {
        try Self.expectAgreement("Host other\n  Port 1\n", aliases: ["a", "Mixed.Case", "10.0.0.1"])
    }

    @Test(.enabled(if: comparesWithSSH)) func firstValueWinsAcrossBlocks() throws {
        try Self.expectAgreement("""
            Host web
              HostName web.example.com
              User deploy
            Host web*
              HostName ignored.example.com
              User ignored
              Port 2200
            Host *
              Port 22
              User fallback
            """, aliases: ["web", "web2", "db"])
    }

    @Test(.enabled(if: comparesWithSSH)) func wildcardsAndNegation() throws {
        try Self.expectAgreement("""
            Host !bastion *.prod
              User prod
            Host db-?
              Port 5432
            Host * !skip
              ForwardAgent yes
            Host A?
              User capital
            """, aliases: ["bastion", "api.prod", "db-1", "db-12", "skip", "Ab", "ab"])
    }

    @Test(.enabled(if: comparesWithSSH)) func hostIsCaseSensitiveButMatchHostIsNot() throws {
        try Self.expectAgreement("""
            Host MIXED
              Port 1
            Match host mixed
              User viamatch
            Match originalhost MiXeD
              ForwardAgent yes
            """, aliases: ["MiXeD", "MIXED", "mixed"])
    }

    @Test(.enabled(if: comparesWithSSH)) func matchCriteria() throws {
        let user = NSUserName()
        try Self.expectAgreement("""
            Host a
              HostName real.example
            Match host real.example user \(user)
              Port 1001
            Match originalhost a,!b
              User via-original
            Match user via-*
              ForwardAgent yes
            Match localuser \(user)
              IdentityFile ~/.ssh/local
            Match !host nothing-matches
              CertificateFile ~/.ssh/cert
            Match exec false
              ProxyJump never
            Match all
              DynamicForward 1080
            """, aliases: ["a", "b", "c"])
    }

    @Test(.enabled(if: comparesWithSSH)) func finalPass() throws {
        try Self.expectAgreement("""
            Host Ab
              HostName Real.Example
            Match canonical
              Port 5
            Match final host real.example
              User fin
            Host real.example
              IdentityFile ~/.ssh/final
            Host ab
              CertificateFile ~/.ssh/lower-alias
            """, aliases: ["Ab", "other"])
        try Self.expectAgreement("""
            Match final
            Host ab
              Port 1
            """, aliases: ["Ab", "ab"])
    }

    @Test(.enabled(if: comparesWithSSH)) func tags() throws {
        try Self.expectAgreement("""
            Host a
              Tag work
            Match tagged work
              Port 7
            Match tagged ""
              User untagged
            """, aliases: ["a", "b"])
    }

    @Test(.enabled(if: comparesWithSSH)) func includesGlobsNestedAndInsideBlocks() throws {
        let fixture = try Fixture()
        let dir = fixture.path
        try fixture.write("inc/20-b.conf", "Host b\n  Port 2002\nHost *\n  User from-b\n")
        try fixture.write("inc/10-a.conf", "Host a\n  Port 1001\n  Include \(dir)/nested.conf\n")
        try fixture.write("nested.conf", "IdentityFile ~/.ssh/nested\nHost b\n  CertificateFile ~/.ssh/nested-b\n")
        try fixture.write("inblock.conf", "ForwardAgent yes\nHost *\n  ProxyJump jump-from-inblock\n")
        try Self.expectAgreement("""
            Include \(dir)/inc/*.conf
            Host c
              Include \(dir)/inblock.conf
              User after-include
            Host d
              Include \(dir)/missing-*.conf \(dir)/inblock.conf
            Host *
              Port 9
            """, aliases: ["a", "b", "c", "d", "e"], fixture: fixture)
    }

    @Test(.enabled(if: comparesWithSSH)) func includeInInactiveBlockNeverMatches() throws {
        let fixture = try Fixture()
        try fixture.write("x.conf", "Host *\n  Port 4444\n")
        try Self.expectAgreement("""
            Host nothing
              Include \(fixture.path)/x.conf
            Host *
              User after
            """, aliases: ["a"], fixture: fixture)
    }

    @Test(.enabled(if: comparesWithSSH)) func tokens() throws {
        try Self.expectAgreement("""
            Host Tok
              HostName %h.Example.COM
              User u-%h-%n-%p-%u-%d-%i-%%-%L-%l
              Port 2022
              IdentityFile ~/.ssh/%h_%r_%p
              CertificateFile %d/certs/%n-cert.pub
              ProxyJump j-%h
            Host env
              User ${HOME}
              HostName h%%x
            """, aliases: ["Tok", "env"])
    }

    @Test(.enabled(if: comparesWithSSH)) func syntaxVariants() throws {
        try Self.expectAgreement(
            "host a\r\n" +
            "HOSTNAME=b.example\r\n" +
            "  port=  7  # trailing comment\r\n" +
            "\tuser = \"q r\"\r\n" +
            "IdentityFile \"~/.ssh/with space\"\n" +
            "IdentityFile '~/.ssh/single'\n" +
            "CertificateFile ~/.ssh/back\\ slash\n" +
            "# comment\n" +
            "   \n" +
            "ProxyCommand=  \"nc\"  %h %p  # kept, as ssh keeps it\n" +
            "Host b\n" +
            "  User u#notacomment\n",
            aliases: ["a", "b"])
    }

    @Test(.enabled(if: comparesWithSSH)) func proxyPrecedence() throws {
        for config in [
            "Host a\n  ProxyJump j\n  ProxyCommand nc %h %p\n",
            "Host a\n  ProxyCommand nc %h %p\n  ProxyJump j\n",
            "Host a\n  ProxyJump none\n  ProxyJump j\n",
            "Host a\n  ProxyJump none\n  ProxyCommand nc x\n",
            "Host a\n  ProxyCommand none\n  ProxyJump j\n",
            "Host a\n  ProxyJump u@j1:2222,j2\n",
            // `none` only as the whole value: with a comment it's a host
            // literally named none, and it still blocks ProxyCommand.
            "Host a\n  ProxyJump none # c\n  ProxyCommand nc x\n",
            "Host a\n  ProxyCommand NONE\n",
            "Host a\n  ProxyCommand none # c\n",
            "Host a\n  ProxyJump \"j1\" # quoted\n",
            "Host a\n  ProxyJump j1,ssh://u@j2:2200\n",
            "Host a\n  ProxyJump j1#c\n  User u%j\n",
        ] {
            try Self.expectAgreement(config, aliases: ["a"])
        }
    }

    @Test(.enabled(if: comparesWithSSH)) func forwards() throws {
        try Self.expectAgreement("""
            Host a
              LocalForward 8080 localhost:80
              LocalForward 8080 localhost:80
              LocalForward 127.0.0.1:8081 db:5432
              LocalForward *:8082 [::1]:80
              LocalForward 8083 db:http
              LocalForward /tmp/relay-local.sock db:1
              RemoteForward 9000
              RemoteForward 0.0.0.0:9001 localhost:22
              DynamicForward 1080
              DynamicForward localhost:1081
              DynamicForward [::1]:1082
            """, aliases: ["a"])
    }

    @Test(.enabled(if: comparesWithSSH)) func identityFilesAccumulateWithoutDuplicates() throws {
        try Self.expectAgreement("""
            Host a
              IdentityFile ~/.ssh/one
              IdentityFile ~/.ssh/two
            Host *
              IdentityFile ~/.ssh/one
              IdentityFile ~/.ssh/three
              CertificateFile ~/.ssh/c
              CertificateFile ~/.ssh/c
            Host none
              IdentityFile none
            """, aliases: ["a", "b", "none"])
    }

    @Test(.enabled(if: comparesWithSSH)) func portServiceNamesAndForwardAgentForms() throws {
        try Self.expectAgreement("""
            Host a
              Port https
              ForwardAgent true
            Host b
              Port ssh
              ForwardAgent ~/agent.sock
            Host c
              ForwardAgent no
              ForwardAgent yes
            """, aliases: ["a", "b", "c"])
    }

    // MARK: Fuzz

    /// Seeded random configs from a grammar of everything above, compared
    /// with `ssh -G` for several aliases each. Configs ssh rejects are
    /// skipped (and counted: most must be accepted).
    @Test(.enabled(if: comparesWithSSH)) func randomConfigsAgreeWithSSH() throws {
        // RELAY_SSHCFG_FUZZ_CASES / _SEED run a bigger or different batch.
        let environment = ProcessInfo.processInfo.environment
        let cases = environment["RELAY_SSHCFG_FUZZ_CASES"].flatMap(Int.init) ?? 220
        var rng = SplitMix64(seed: environment["RELAY_SSHCFG_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x5EED_C0F1)
        var compared = 0, rejected = 0
        var failures: [String] = []
        for index in 0..<cases {
            let fixture = try Fixture()
            let config = try ConfigGrammar.config(&rng, fixture: fixture)
            let path = try fixture.write("config", config)
            for alias in ConfigGrammar.aliases {
                guard let ssh = try Self.sshG(config: path, alias: alias) else { rejected += 1; continue }
                compared += 1
                let diffs = Self.differences(Self.evaluate(config: path, alias: alias), ssh)
                if !diffs.isEmpty, failures.count < 5 {
                    failures.append("case \(index) alias \(alias): \(diffs.joined(separator: "; "))\n\(config)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n\n"))")
        #expect(compared > rejected * 4, "compared \(compared), ssh rejected \(rejected)")
    }

    // MARK: Without ssh (sandbox semantics)

    static func virtualEnvironment(files: [String: String], home: String = "/Users/someone") -> SSHConfigEvaluator.Environment {
        SSHConfigEvaluator.Environment(
            home: home, localUser: "someone", uid: 501, localHostname: "mac.local",
            readFile: { files[$0] },
            glob: { pattern in
                files.keys.filter { SSHConfigEvaluator.wildcardMatch($0, pattern) }.sorted()
            },
            variable: { $0 == "HOME" ? "/container/home" : nil })
    }

    @Test func relativeIncludesResolveAgainstTheInjectedHome() {
        let env = Self.virtualEnvironment(files: [
            "/Users/someone/.ssh/config": "Include conf.d/*\nInclude ~/extra\n",
            "/Users/someone/.ssh/conf.d/b": "Host x\n  Port 2\n",
            "/Users/someone/.ssh/conf.d/a": "Host x\n  Port 1\n  User from-a\n",
            "/Users/someone/extra": "Host x\n  HostName extra.example\n",
        ])
        let values = SSHConfigEvaluator.evaluate(alias: "x", configPath: "/Users/someone/.ssh/config", environment: env)
        #expect(values["port"] == ["1"])
        #expect(values["user"] == ["from-a"])
        #expect(values["hostname"] == ["extra.example"])
    }

    @Test func tildeAndDirectoryTokensUseTheRealHomeNotTheContainer() {
        let env = Self.virtualEnvironment(files: [
            "/Users/someone/.ssh/config": "Host x\n  User u-%d\n  ForwardAgent ~/agent\n",
        ])
        let values = SSHConfigEvaluator.evaluate(alias: "x", configPath: "/Users/someone/.ssh/config", environment: env)
        #expect(values["user"] == ["u-/Users/someone"])
        #expect(values["forwardagent"] == ["/Users/someone/agent"])
    }

    @Test func matchExecNeverMatchesAndRunsNothing() {
        let env = Self.virtualEnvironment(files: [
            "/c": "Match exec \"touch /tmp/relay-should-not-exist\"\n  Port 1\nMatch !exec true\n  User negated\n",
        ])
        let values = SSHConfigEvaluator.evaluate(alias: "x", configPath: "/c", environment: env)
        #expect(values["port"] == ["22"])
        // ssh would run `true` and not match; here exec is false, negated.
        #expect(values["user"] == ["negated"])
    }

    @Test func includeCyclesStop() {
        let env = Self.virtualEnvironment(files: [
            "/c": "Include /c\nHost x\n  Port 3\n",
        ])
        let values = SSHConfigEvaluator.evaluate(alias: "x", configPath: "/c", environment: env)
        #expect(values["port"] == ["3"])
    }

    @Test func linesSSHWouldRejectAreSkipped() {
        let env = Self.virtualEnvironment(files: [
            "/c": "Host x\n  NotAKeyword yes\n  Port 70000\n  HostName two words\n  User \"unclosed\n  Port 2\n  User ok\n",
        ])
        let values = SSHConfigEvaluator.evaluate(alias: "x", configPath: "/c", environment: env)
        #expect(values["port"] == ["2"])
        #expect(values["hostname"] == ["x"])
        #expect(values["user"] == ["ok"])
        #expect(values["notakeyword"] == ["yes"])
    }

    @Test func missingConfigYieldsDefaults() {
        let values = SSHConfigEvaluator.evaluate(alias: "Box", configPath: "/nope", environment: Self.virtualEnvironment(files: [:]))
        #expect(values["hostname"] == ["box"])
        #expect(values["user"] == ["someone"])
        #expect(values["port"] == ["22"])
        #expect(values["identityfile"] == SSHConfigEvaluator.defaultIdentityFiles)
    }

    @Test func renderedOutputFeedsTheImporter() {
        let env = Self.virtualEnvironment(files: [
            "/c": """
                Host box
                  HostName box.example.com
                  User deploy
                  Port 2222
                  IdentityFile ~/.ssh/box
                  CertificateFile ~/.ssh/box-cert.pub
                  ProxyJump bastion
                  LocalForward 8080 localhost:80
                  ForwardAgent yes
                Host plain
                """,
        ])
        let box = SSHConfigImporter.host(
            alias: "box", effectiveConfig: SSHConfigEvaluator.effectiveConfig(alias: "box", configPath: "/c", environment: env))
        #expect(box.hostname == "box.example.com")
        #expect(box.user == "deploy")
        #expect(box.port == 2222)
        #expect(box.auth == .keyFile(path: "~/.ssh/box", certificatePath: "~/.ssh/box-cert.pub"))
        #expect(box.inheritedOptions == ["LocalForward 8080 [localhost]:80", "ForwardAgent yes"])

        let plain = SSHConfigImporter.host(
            alias: "plain", effectiveConfig: SSHConfigEvaluator.effectiveConfig(alias: "plain", configPath: "/c", environment: env))
        #expect(plain.auth == .automatic)
        #expect(plain.port == nil)
        #expect(plain.inheritedOptions.isEmpty)
    }

    @Test func patternListSemantics() {
        #expect(SSHConfigEvaluator.patternListMatch("web1", "web*,!web2", ignoringCase: false))
        #expect(!SSHConfigEvaluator.patternListMatch("web2", "web*,!web2", ignoringCase: false))
        #expect(!SSHConfigEvaluator.patternListMatch("db", "!web2", ignoringCase: false))
        #expect(SSHConfigEvaluator.patternListMatch("WEB", "web", ignoringCase: true))
        #expect(SSHConfigEvaluator.wildcardMatch("a.b.c", "*.c"))
        #expect(SSHConfigEvaluator.wildcardMatch("abc", "a?c"))
        #expect(!SSHConfigEvaluator.wildcardMatch("ac", "a?c"))
        #expect(SSHConfigEvaluator.wildcardMatch("", "*"))
        #expect(SSHConfigEvaluator.wildcardMatch("aXbXc", "a*b*c"))
    }
}

// MARK: - Random configs

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum ConfigGrammar {
    static let aliases = ["a", "Ab", "web-1", "db.prod", "x"]
    static let patterns = ["*", "a", "Ab", "ab", "a*", "?b", "web-?", "*.prod", "x", "db*", "nomatch", "*-1", "real*"]
    static let hostnames = ["real.example", "%h.example", "Real.Upper", "10.0.0.5", "web-1", "h%%x"]

    static func pick<T>(_ items: [T], _ rng: inout SplitMix64) -> T { items[Int(rng.next() % UInt64(items.count))] }
    static func chance(_ percent: UInt64, _ rng: inout SplitMix64) -> Bool { rng.next() % 100 < percent }

    static func keyword(_ name: String, _ rng: inout SplitMix64) -> String {
        switch rng.next() % 4 {
        case 0: return name.lowercased()
        case 1: return name.uppercased()
        default: return name
        }
    }

    static func separator(_ rng: inout SplitMix64) -> String { pick([" ", " ", "  ", "=", " = ", "\t"], &rng) }

    static func value(_ text: String, _ rng: inout SplitMix64) -> String {
        guard !text.contains(" ") else { return "\"\(text)\"" }
        return chance(15, &rng) ? "\"\(text)\"" : text
    }

    static func directive(_ rng: inout SplitMix64) -> String {
        let user = NSUserName()
        let (name, arg): (String, String)
        switch rng.next() % 13 {
        case 0: (name, arg) = ("HostName", pick(hostnames, &rng))
        case 1: (name, arg) = ("User", pick(["deploy", "u-%h", "u-%n-%p", "root", user, "${HOME}", "x%%y", "two words"], &rng))
        case 2: (name, arg) = ("Port", pick(["22", "2200", "443", "ssh", "https", "65535"], &rng))
        case 3: (name, arg) = ("IdentityFile", pick(["~/.ssh/id_a", "~/.ssh/id_b", "%d/k_%h", "none", "~/.ssh/id_ed25519"], &rng))
        case 4: (name, arg) = ("CertificateFile", pick(["~/.ssh/c1", "~/.ssh/c2", "%d/c-%n"], &rng))
        case 5: (name, arg) = ("ProxyJump", pick(["none", "NONE", "j1", "u@j2:2222", "j1,j2", "j-%h", "ssh://u@j3:2200", "j1,ssh://j4"], &rng))
        case 6: (name, arg) = ("ProxyCommand", pick(["nc %h %p", "none", "ssh -W %h:%p j"], &rng))
        case 7: (name, arg) = ("LocalForward", pick(["8080 localhost:80", "127.0.0.1:8081 db:5432", "*:8082 [::1]:80", "8083 db:http"], &rng))
        case 8: (name, arg) = ("RemoteForward", pick(["9000", "0.0.0.0:9001 localhost:22", "9002 h:2"], &rng))
        case 9: (name, arg) = ("DynamicForward", pick(["1080", "localhost:1081", "[::1]:1082"], &rng))
        case 10: (name, arg) = ("ForwardAgent", pick(["yes", "no", "true", "false"], &rng))
        case 11: (name, arg) = ("Tag", pick(["t1", "t2"], &rng))
        default: (name, arg) = ("ServerAliveInterval", pick(["15", "30"], &rng))
        }
        let rendered: String
        switch name {
        case "ProxyCommand", "LocalForward", "RemoteForward": rendered = arg
        default: rendered = value(arg, &rng)
        }
        let comment = chance(10, &rng) && name != "ProxyCommand" ? "  # note" : ""
        return pick(["  ", "\t", "", "    "], &rng) + keyword(name, &rng) + separator(&rng) + rendered + comment
    }

    static func hostLine(_ rng: inout SplitMix64) -> String {
        var items: [String] = []
        for _ in 0..<(1 + rng.next() % 3) {
            let pattern = pick(patterns, &rng)
            items.append(chance(15, &rng) && pattern != "*" ? "!" + pattern : pattern)
        }
        if items.allSatisfy({ $0.hasPrefix("!") }) { items.append("*") }
        return keyword("Host", &rng) + " " + items.joined(separator: " ")
    }

    static func matchLine(_ rng: inout SplitMix64) -> String {
        let user = NSUserName()
        if chance(15, &rng) { return "Match " + pick(["all", "final", "canonical", "final all", "canonical all"], &rng) }
        var criteria: [String] = []
        for _ in 0..<(1 + rng.next() % 2) {
            let negate = chance(15, &rng) ? "!" : ""
            switch rng.next() % 8 {
            case 0: criteria.append("\(negate)host \(pick(["real.example", "a,b", "*.example", "!x,*", "web-*", "ab"], &rng))")
            case 1: criteria.append("\(negate)originalhost \(pick(["a", "Ab", "*.prod", "x,a"], &rng))")
            case 2: criteria.append("\(negate)user \(pick(["deploy", "root", user, "u-*"], &rng))")
            case 3: criteria.append("\(negate)localuser \(pick([user, "nobody"], &rng))")
            case 4: criteria.append("\(negate)tagged \(pick(["t1", "t2"], &rng))")
            case 5: criteria.append("exec false")
            case 6: criteria.append("\(negate)final")
            default: criteria.append("\(negate)canonical")
            }
        }
        return keyword("Match", &rng) + " " + criteria.joined(separator: " ")
    }

    static func config(_ rng: inout SplitMix64, fixture: SSHConfigEvaluatorTests.Fixture) throws -> String {
        var lines: [String] = []
        for _ in 0..<(rng.next() % 3) { lines.append(directive(&rng)) }
        var includes = 0
        for _ in 0..<(1 + rng.next() % 6) {
            lines.append(chance(70, &rng) ? hostLine(&rng) : matchLine(&rng))
            for _ in 0..<(1 + rng.next() % 4) { lines.append(directive(&rng)) }
            if chance(20, &rng) {
                includes += 1
                let name = "inc\(includes)"
                var included: [String] = []
                for _ in 0..<(1 + rng.next() % 3) { included.append(directive(&rng)) }
                if chance(25, &rng) {
                    // A nested include, from inside the included file.
                    try fixture.write("\(name)-nested.conf", [matchLine(&rng), directive(&rng), directive(&rng)].joined(separator: "\n") + "\n")
                    included.append("Include \(fixture.path)/\(name)-nested.conf")
                }
                if chance(50, &rng) {
                    included.append(hostLine(&rng))
                    for _ in 0..<(1 + rng.next() % 3) { included.append(directive(&rng)) }
                }
                try fixture.write("\(name)-1.conf", included.joined(separator: "\n") + "\n")
                if chance(40, &rng) {
                    try fixture.write("\(name)-0.conf", directive(&rng) + "\n")
                }
                lines.append("  Include \(fixture.path)/\(name)-*.conf")
            }
            if chance(10, &rng) { lines.append(pick(["", "# comment", "   "], &rng)) }
        }
        let eol = chance(10, &rng) ? "\r\n" : "\n"
        return lines.joined(separator: eol) + eol
    }
}
