import CryptoKit
import Foundation
import RelaySSH
import RelayTestSupport
import Testing
@testable import RelayCore

@Suite("This Mac as a host")
struct LocalHostTests {
    // MARK: Pure

    @Test func matchesKeysIgnoringComments() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample"
        #expect(LocalSSHIdentity.matches(trustedKeys: [key], localKey: key + " root@mac"))
        #expect(LocalSSHIdentity.matches(trustedKeys: ["ecdsa-sha2-nistp256 AAAA", key], localKey: key))
        #expect(!LocalSSHIdentity.matches(trustedKeys: ["ssh-ed25519 AAAAother"], localKey: key))
        #expect(!LocalSSHIdentity.matches(trustedKeys: [key], localKey: nil))
        #expect(!LocalSSHIdentity.matches(trustedKeys: [], localKey: key))
    }

    @Test func tellsTailnetAndLANAddresses() {
        #expect(LocalNetworkAddresses.isTailnet("100.88.232.49"))
        #expect(LocalNetworkAddresses.isTailnet("100.64.0.1"))
        #expect(LocalNetworkAddresses.isTailnet("100.127.255.254"))
        #expect(!LocalNetworkAddresses.isTailnet("100.128.0.1"))
        #expect(!LocalNetworkAddresses.isTailnet("100.63.255.255"))
        #expect(LocalNetworkAddresses.isTailnet("fd7a:115c:a1e0::1"))
        #expect(!LocalNetworkAddresses.isTailnet("fd7a:115c:a1e1::1"))
        #expect(LocalNetworkAddresses.isLAN("192.168.1.20"))
        #expect(LocalNetworkAddresses.isLAN("10.0.0.5"))
        #expect(LocalNetworkAddresses.isLAN("172.20.1.1"))
        #expect(!LocalNetworkAddresses.isLAN("172.32.1.1"))
        #expect(!LocalNetworkAddresses.isLAN("100.88.232.49"))
    }

    @Test func loopbackKeepsTheHostKeyName() {
        let host = SSHHost(alias: "mac", hostname: "mac.tailnet.ts.net", user: "me", proxyJump: "bastion")
        let target = SSHTarget(
            host: "mac.tailnet.ts.net", port: 22, username: "me", credentials: .storedKey(id: "k"),
            jumps: [SSHTarget(host: "bastion", username: "me", credentials: .automatic)])
        let loopback = BuiltInSSHRouter.loopback(target, host: host, port: 22)
        #expect(loopback.host == "127.0.0.1")
        #expect(loopback.port == 22)
        #expect(loopback.jumps.isEmpty)
        #expect(loopback.credentials == .storedKey(id: "k"))
        #expect(loopback.username == "me")
        #expect(loopback.hostKeyAlias == .init(host: "mac.tailnet.ts.net", port: 22))
    }

    @Test func suggestsAliasesFromTheComputerName() {
        #expect(SSHHost.suggestedAlias(forComputerName: "Iddo\u{2019}s MacBook Pro", taken: []) == "iddos-macbook-pro")
        #expect(SSHHost.suggestedAlias(forComputerName: "Mac mini", taken: ["mac-mini"]) == "mac-mini-2")
        #expect(SSHHost.suggestedAlias(forComputerName: "\u{1F34E}", taken: []) == "this-mac")
        #expect(SSHHost.isValidAlias(SSHHost.suggestedAlias(forComputerName: "A -- B..C", taken: [])))
    }

    // MARK: tmux install

    @Test func parsesTheHostProbe() {
        let platform = TmuxInstaller.parseProbe("""
            RTERM_OS=Linux
            RTERM_ARCH=aarch64
            RTERM_PM=/usr/bin/apt-get
            RTERM_SUDO=needsPassword
            RTERM_UNPACK=yes
            """)
        #expect(platform.os == "Linux")
        #expect(platform.tmuxPath == nil)
        #expect(platform.bundledAssetName == "tmux-linux-aarch64.gz")
        #expect(platform.packageInstallCommand == "sudo apt-get update && sudo apt-get install -y tmux")
        #expect(!platform.packageInstallIsUnattended)
    }

    @Test func picksTheBundledBinary() {
        func platform(_ os: String, _ arch: String, unpack: Bool = true) -> HostPlatform {
            HostPlatform(os: os, arch: arch, sudo: .unavailable, canUnpack: unpack)
        }
        #expect(platform("Darwin", "arm64").bundledAssetName == "tmux-darwin-universal.gz")
        #expect(platform("Darwin", "x86_64").bundledAssetName == "tmux-darwin-universal.gz")
        #expect(platform("Linux", "x86_64").bundledAssetName == "tmux-linux-x86_64.gz")
        #expect(platform("Linux", "arm64").bundledAssetName == "tmux-linux-aarch64.gz")
        #expect(platform("Linux", "armv7l").bundledAssetName == nil)
        #expect(platform("FreeBSD", "amd64").bundledAssetName == nil)
        #expect(platform("Linux", "x86_64", unpack: false).bundledAssetName == nil)
    }

    @Test func packageManagerCommands() {
        func command(_ manager: String, _ sudo: HostPlatform.Sudo) -> String? {
            HostPlatform(os: "Linux", arch: "x86_64", packageManager: manager, sudo: sudo, canUnpack: true)
                .packageInstallCommand
        }
        #expect(command("/opt/homebrew/bin/brew", .unavailable) == "\(POSIXShellQuote.quote("/opt/homebrew/bin/brew")) install tmux")
        #expect(command("/usr/bin/dnf", .root) == "dnf install -y tmux")
        #expect(command("/sbin/apk", .passwordless) == "sudo apk add tmux")
        #expect(command("/usr/bin/apt-get", .unavailable) == nil)
        let brew = HostPlatform(os: "Darwin", arch: "arm64", packageManager: "/opt/homebrew/bin/brew", sudo: .needsPassword, canUnpack: true)
        #expect(brew.packageInstallIsUnattended)
    }

    @Test func findTmuxLooksInRelaysInstall() {
        #expect(SSHTmuxScripts.resolveTmuxFragment.contains("\"$HOME/.relay/bin/tmux\""))
        #expect(TmuxInstaller.probeScript.contains("find_tmux()"))
    }

    // MARK: Live (a real sshd on loopback)

    /// A host named for another network, trusted with the sshd's key: the
    /// router sees it's "this Mac" and dials loopback, and the handshake
    /// checks the key under the host's own name.
    @Test func reachesThisMacOverLoopback() async throws {
        let sshd = try TestSSHD()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("relay-local-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var options = SSHConnectionPool.Options()
        let trustFile = scratch.appendingPathComponent("known_hosts").path
        options.knownHostsFiles = [trustFile]
        options.agent = nil
        let pool = SSHConnectionPool(options: options)

        let identity = LocalSSHIdentity(port: sshd.port)
        let presented = try #require(await identity.refresh(pool: pool, force: true))
        let expected = try String(contentsOfFile: sshd.knownHostsPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").dropFirst().prefix(2).joined(separator: " ")
        #expect(presented == expected)

        let host = SSHHost(
            alias: "my-mac", hostname: "my-mac.example.ts.net", user: NSUserName(),
            auth: .keyFile(path: sshd.clientKeyPath, certificatePath: nil))
        let other = SSHHost(alias: "elsewhere", hostname: "elsewhere.example", user: NSUserName())
        try KnownHosts.trust(host: host.hostname, port: 22, presentedKey: presented, in: trustFile)
        let router = BuiltInSSHRouter(
            registry: SSHHostRegistry(hosts: [host, other]), pool: pool, trustedHostsFile: trustFile,
            localIdentity: identity, knownHostsFiles: [trustFile], passwordLookup: { _ in nil })

        #expect(router.isThisMac(alias: "my-mac"))
        #expect(!router.isThisMac(alias: "elsewhere"))
        guard case .ready(let target) = router.connection(for: "my-mac") else {
            Issue.record("not ready")
            return
        }
        #expect(target.host == "127.0.0.1" && target.port == sshd.port)
        let result = try await pool.exec(target: target, command: "printf ok", stdin: Data(), timeout: .seconds(20))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "ok")

        // Remote Login turned off: back to the host's own address.
        sshd.stop()
        #expect(await identity.refresh(pool: pool, force: true) == nil)
        router.hostsChanged()
        #expect(!router.isThisMac(alias: "my-mac"))
        if case .ready(let direct) = router.connection(for: "my-mac") {
            #expect(direct.host == "my-mac.example.ts.net")
        }
    }

    @Test func probeFindsNothingWhereNothingListens() async throws {
        let pool = SSHConnectionPool()
        // A port that was free a moment ago.
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        close(socket)
        #expect(await pool.probeHostKey(host: "127.0.0.1", port: port, timeout: .seconds(2)) == nil)
    }
}

@Suite("MagicDNS reverse lookup")
struct MagicDNSTests {
    @Test func buildsAPTRQuery() {
        let query = MagicDNS.ptrQuery(name: "49.232.88.100.in-addr.arpa", id: 0x1234)
        #expect(Array(query.prefix(12)) == [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        #expect(query[12] == 2 && query[13...14].elementsEqual(Array("49".utf8)))
        #expect(Array(query.suffix(5)) == [0, 0, 12, 0, 1])
    }

    @Test func readsTheAnswerWithCompression() {
        let query = MagicDNS.ptrQuery(name: "1.0.64.100.in-addr.arpa", id: 7)
        var response = query
        response[2] = 0x81; response[3] = 0x80; response[7] = 1  // QR, RA; 1 answer
        func name(_ labels: [String]) -> [UInt8] { labels.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } }
        let rdata = name(["mac", "tail1", "ts", "net"]) + [0]
        response += [0xC0, 12, 0, 12, 0, 1, 0, 0, 0, 60, 0, UInt8(rdata.count)] + rdata
        #expect(MagicDNS.parsePTRAnswer(response, id: query.prefix(2)) == "mac.tail1.ts.net")
        // Someone else's answer, or an error, is ignored.
        #expect(MagicDNS.parsePTRAnswer(response, id: [0, 8]) == nil)
        response[3] = 0x83
        #expect(MagicDNS.parsePTRAnswer(response, id: query.prefix(2)) == nil)
    }

    @Test func asksTailscaleWhenItsRunning() throws {
        let tailnet = LocalNetworkAddresses.interfaceAddresses().first {
            LocalNetworkAddresses.isTailnet($0.address) && !$0.address.contains(":")
        }
        guard let tailnet else { return }  // no Tailscale here
        let started = ContinuousClock.now
        let name = MagicDNS.reverseLookup(ipv4: tailnet.address)
        #expect(ContinuousClock.now - started < .seconds(2))
        // nil when MagicDNS is off; a name is always a tailnet one.
        if let name { #expect(name.hasSuffix(".ts.net")) }
    }
}

/// The install scripts run for real, with `/bin/sh` in a scratch home.
@Suite("tmux install scripts")
struct TmuxInstallScriptTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// Runs `script` with `input` on stdin; returns its exit status.
    func run(_ script: String, input: Data) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func gzip(_ data: Data) throws -> Data {
        let source = home.appendingPathComponent("payload")
        try data.write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-kf", source.path]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: home.appendingPathComponent("payload.gz"))
    }

    func sha256(_ data: Data) -> String {
        SHA256Hex.of(data)
    }

    @Test func installsAMatchingBinary() throws {
        let binary = Data("#!/bin/sh\necho tmux\n".utf8)
        let status = try run(TmuxInstaller.binaryScript(version: "9.9", sha256: sha256(binary)), input: try gzip(binary))
        #expect(status == 0)
        #expect(FileManager.default.contents(atPath: home.appendingPathComponent(".relay/tmux/9.9/tmux").path) == binary)
    }

    @Test func refusesAMismatchedBinary() throws {
        let binary = Data("#!/bin/sh\necho tmux\n".utf8)
        let status = try run(TmuxInstaller.binaryScript(version: "9.9", sha256: String(repeating: "0", count: 64)), input: try gzip(binary))
        #expect(status == 31)
        let left = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".relay/tmux/9.9").path)
        #expect(left.isEmpty)
    }

    @Test func refusesATruncatedUpload() throws {
        let binary = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761) })
        let compressed = try gzip(binary)
        let status = try run(TmuxInstaller.binaryScript(version: "9.9", sha256: sha256(binary)), input: compressed.prefix(compressed.count / 2))
        #expect(status != 0)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".relay/tmux/9.9/tmux").path))
    }

    @Test func checksTheTerminfoTarball() throws {
        let tarball = try gzip(Data("not checked before the checksum".utf8))
        #expect(try run(TmuxInstaller.terminfoScript(sha256: String(repeating: "0", count: 64)), input: tarball) == 31)
    }

    @Test func unpacksAMatchingTerminfoTarball() throws {
        let entry = home.appendingPathComponent("src/x")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("entry".utf8).write(to: entry.appendingPathComponent("xterm-test"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", home.appendingPathComponent("t.tar.gz").path, "-C", home.appendingPathComponent("src").path, "x"]
        try tar.run()
        tar.waitUntilExit()
        let tarball = try Data(contentsOf: home.appendingPathComponent("t.tar.gz"))
        #expect(try run(TmuxInstaller.terminfoScript(sha256: sha256(tarball)), input: tarball) == 0)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".relay/terminfo/x/xterm-test").path))
    }
}

enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
