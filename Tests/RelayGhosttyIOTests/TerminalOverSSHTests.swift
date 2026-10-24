import AppKit
import Darwin
import Foundation
import GhosttyKit
import RelayTestSupport
import Testing
@testable import RelayGhosttyIO
@testable import RelaySSH

/// The whole path, end to end: a libghostty surface in manual I/O mode,
/// connected by `SSHTerminalLink` over Relay's SSH client to a server
/// running real programs on a real pty. Each scenario runs against the
/// in-process fake server and against a real OpenSSH sshd; assertions read
/// what the terminal actually shows.
extension GhosttyIOSuites {
@Suite("Terminal over SSH (end to end)", .serialized)
@MainActor
struct TerminalOverSSHTests {
    enum Remote: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case fake
        case sshd
        var testDescription: String { rawValue }
    }

    /// One server of each kind for the whole suite.
    @MainActor
    enum Servers {
        static let scratch = try! makeScratchDirectory("e2e")
        static let fake = try! FakeSSHServer(shell: ["/bin/sh", "-i"])
        static let fakePool: SSHConnectionPool = {
            var options = SSHConnectionPool.Options()
            options.knownHostsFiles = [try! fake.writeKnownHosts(in: scratch)]
            options.agent = nil
            options.defaultKeyFiles = []
            return SSHConnectionPool(options: options)
        }()
        static let sshd = Result { try TestSSHD() }
        static let sshdPool: SSHConnectionPool? = {
            guard case .success(let sshd) = sshd else { return nil }
            var options = SSHConnectionPool.Options()
            options.knownHostsFiles = [sshd.knownHostsPath]
            options.agent = nil
            options.defaultKeyFiles = []
            return SSHConnectionPool(options: options)
        }()

        static func endpoint(_ remote: Remote) throws -> (SSHConnectionPool, SSHTarget) {
            switch remote {
            case .fake:
                return (fakePool, fake.target)
            case .sshd:
                let server = try sshd.get()
                return (sshdPool!, server.target)
            }
        }
    }

    static let shell = "exec env PS1='relay$ ' /bin/bash --noprofile --norc -i"
    static let prompt = "relay$ "

    /// A terminal on the test host, linked to `remote`.
    final class Terminal {
        let surface: TestSurface
        let link: SSHTerminalLink
        let ends = EndLog()

        @MainActor
        init(_ remote: Remote, command: String?, width: Double = 800, height: Double = 480,
             waitAfterCommand: Bool = false, target override: SSHTarget? = nil,
             environment: [(String, String)] = [("LANG", "en_US.UTF-8")]) throws {
            let (pool, target) = try Servers.endpoint(remote)
            let io = ManualTerminalIO()
            surface = TestSurface(mode: .manual(io), width: width, height: height,
                                  waitAfterCommand: waitAfterCommand, captureIO: false)
            try #require(surface.surface != nil)
            let ends = ends
            link = SSHTerminalLink(
                io: io, pool: pool,
                configuration: .init(target: override ?? target, command: command, environment: environment),
                onEnd: { end, error in ends.record(end, error) })
            link.start()
        }

        @MainActor
        func typeLine(_ line: String) {
            surface.typeKeys(line)
            surface.press(keycode: Key.returnKey)
        }

        @MainActor
        func close() async throws {
            link.close()
            try await surface.free()
        }
    }

    // MARK: Shells and programs

    @Test(arguments: Remote.allCases)
    func anInteractiveShellRoundTrips(remote: Remote) async throws {
        let terminal = try Terminal(remote, command: Self.shell)
        try await terminal.surface.waitForScreen(Self.prompt, timeout: .seconds(20))
        terminal.typeLine("echo answer=$((6*7))")
        try await terminal.surface.waitForScreen("answer=42")
        terminal.typeLine("exit 3")
        try await terminal.surface.waitForClose()
        try await GhosttyTestHost.shared.waitUntil("the end") { terminal.ends.end != nil }
        #expect(terminal.ends.end == .exited(3))
        try await terminal.surface.free()
    }

    @Test(arguments: Remote.allCases)
    func theRemotePTYTracksTheTerminalSize(remote: Remote) async throws {
        let terminal = try Terminal(
            remote,
            command: "/bin/sh -c \"trap 'echo size \\$(stty size)' WINCH; echo start \\$(stty size); while :; do sleep 0.02; done\"")
        let surface = terminal.surface

        /// The program's latest view of its size matches the terminal's
        /// (the pty may open before libghostty settles on its first size;
        /// a window-change then follows).
        func remoteAgrees() async throws {
            try await GhosttyTestHost.shared.waitUntil("the remote size", screen: { surface.screen }) {
                guard let grid = surface.gridSize else { return false }
                let lines = surface.allText.components(separatedBy: "\n").filter { $0.hasPrefix("start ") || $0.hasPrefix("size ") }
                guard let last = lines.last else { return false }
                return last.hasSuffix(" \(grid.rows) \(grid.columns)")
            }
        }
        try await remoteAgrees()
        let initial = try #require(surface.gridSize)

        surface.setSize(width: 1100, height: 700)
        try await GhosttyTestHost.shared.waitUntil("a new grid") { surface.gridSize != initial }
        try await remoteAgrees()
        let grown = try #require(surface.gridSize)

        surface.setSize(width: 500, height: 300)
        try await GhosttyTestHost.shared.waitUntil("a new grid") { surface.gridSize != grown }
        try await remoteAgrees()
        try await terminal.close()
    }

    @Test(arguments: Remote.allCases)
    func vimWorksFullScreen(remote: Remote) async throws {
        let terminal = try Terminal(remote, command: "vim -u NONE -i NONE -N -n")
        let surface = terminal.surface
        // Empty-buffer lines.
        try await GhosttyTestHost.shared.waitUntil("vim to draw", timeout: .seconds(20), screen: { surface.screen }) {
            surface.screenLines.filter { $0.hasPrefix("~") }.count > 5
        }
        surface.typeKeys("ihello from vim")
        surface.press(keycode: Key.escape)
        try await surface.waitForScreen("hello from vim")
        terminal.typeLine(":q!")
        try await surface.waitForClose()
        try await GhosttyTestHost.shared.waitUntil("the end") { terminal.ends.end != nil }
        #expect(terminal.ends.end == .exited(0))
        try await surface.free()
    }

    @Test(arguments: Remote.allCases)
    func tmuxRunsAndFollowsResizes(remote: Remote) async throws {
        let tmux = try #require(Self.tmuxPath, "tmux must be installed")
        let socket = "relay-e2e-\(UUID().uuidString.prefix(8))"
        // A private server (-L) and no config: never touches real sessions.
        let terminal = try Terminal(remote, command: "\(tmux) -L \(socket) -f /dev/null new-session -s e2e")
        defer {
            Self.run(tmux, ["-L", socket, "kill-server"])
            try? FileManager.default.removeItem(atPath: "/private/tmp/tmux-\(getuid())/\(socket)")
        }
        let surface = terminal.surface
        try await surface.waitForScreen("[e2e]", timeout: .seconds(20))
        terminal.typeLine("echo tmux-$((2+3))")
        try await surface.waitForScreen("tmux-5")

        func clientSize() -> String {
            Self.run(tmux, ["-L", socket, "list-clients", "-F", "#{client_width}x#{client_height}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let initial = try #require(surface.gridSize)
        try await GhosttyTestHost.shared.waitUntil("tmux to see the size") {
            clientSize() == "\(initial.columns)x\(initial.rows)"
        }
        surface.setSize(width: 1000, height: 640)
        try await GhosttyTestHost.shared.waitUntil("a new grid") { surface.gridSize != initial }
        let grown = try #require(surface.gridSize)
        try await GhosttyTestHost.shared.waitUntil("tmux to follow", screen: { clientSize() }) {
            clientSize() == "\(grown.columns)x\(grown.rows)"
        }
        // Detach (prefix, d): tmux exits, the session stays.
        surface.press(keycode: 11, mods: GHOSTTY_MODS_CTRL, unshifted: "b")
        surface.typeKeys("d")
        try await surface.waitForClose()
        #expect(Self.run(tmux, ["-L", socket, "list-sessions", "-F", "#{session_name}"]).contains("e2e"))
        try await surface.free()
    }

    @Test(arguments: Remote.allCases)
    func controlCInterruptsAndTheShellCarriesOn(remote: Remote) async throws {
        let terminal = try Terminal(remote, command: Self.shell)
        let surface = terminal.surface
        try await surface.waitForScreen(Self.prompt, timeout: .seconds(20))
        // Markers are computed by the shell, so the typed command line
        // itself never matches. bash carries on with the list once the
        // interrupted sleep is gone, so the marker shows up in seconds —
        // not after 30 — only if ^C really interrupted it.
        terminal.typeLine("sleep 30; echo sleep-$((1+1))-over")
        try await Task.sleep(for: .milliseconds(300))
        let interruptedAt = ContinuousClock.now
        surface.press(keycode: Key.c, mods: GHOSTTY_MODS_CTRL, unshifted: "c")
        try await surface.waitForScreen("sleep-2-over", timeout: .seconds(5))
        #expect(ContinuousClock.now - interruptedAt < .seconds(5))
        #expect(surface.allText.contains("^C"))
        terminal.typeLine("echo still-$((2+2))-alive")
        try await surface.waitForScreen("still-4-alive")
        try await terminal.close()
    }

    // MARK: Data

    @Test(arguments: Remote.allCases)
    func largeOutputStreamsAndTheTerminalStaysResponsive(remote: Remote) async throws {
        let terminal = try Terminal(remote, command: Self.shell)
        let surface = terminal.surface
        try await surface.waitForScreen(Self.prompt, timeout: .seconds(20))
        let started = ContinuousClock.now
        terminal.typeLine("seq 1 300000; echo SEQ-$((1+1))-DONE")
        try await surface.waitForScreen("SEQ-2-DONE", timeout: .seconds(60))
        let elapsed = ContinuousClock.now - started
        #expect(surface.allText.contains("\n299999\n300000\n"))
        terminal.typeLine("echo after-$((3+3))")
        try await surface.waitForScreen("after-6")
        print("[e2e] \(remote): seq 1 300000 (≈2 MB) rendered in \(elapsed)")
        try await terminal.close()
    }

    @Test(arguments: Remote.allCases)
    func unicodeSurvivesBothDirections(remote: Remote) async throws {
        let terminal = try Terminal(remote, command: Self.shell)
        let surface = terminal.surface
        try await surface.waitForScreen(Self.prompt, timeout: .seconds(20))
        let text = "✓ 日本語 🚀 naïve"
        terminal.typeLine("echo \"\(text)\" | od -An -tx1 | tr -d ' \\n'; echo")
        let hex = Array(text.utf8).map { String(format: "%02x", $0) }.joined() + "0a"
        try await surface.waitForScreen(hex)
        terminal.typeLine("echo \"<\(text)>\"")
        try await surface.waitForScreen("<\(text)>\n")
        try await terminal.close()
    }

    @Test(arguments: Remote.allCases)
    func typedInputArrivesIntact(remote: Remote) async throws {
        let count = 3000
        let terminal = try Terminal(remote, command: "stty raw -echo; echo ready; head -c \(count) | shasum -a 256; sleep 2")
        let surface = terminal.surface
        try await surface.waitForScreen("ready")
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ-_=+[]{};:,./?")
        var input = ""
        for i in 0..<count { input.append(alphabet[(i * 7 + i / 13) % alphabet.count]) }
        // As keystrokes, as fast as they come.
        surface.typeKeys(input)
        try await surface.waitForScreen(Self.sha256(Data(input.utf8)))
        try await terminal.close()
    }

    @Test(arguments: Remote.allCases)
    func bracketedPasteReachesTheProgramIntact(remote: Remote) async throws {
        // What the program should read: the paste, bracketed, verbatim
        // (libghostty keeps newlines inside a bracketed paste).
        let expected = Data("\u{1B}[200~one\ntwo three\u{1B}[201~".utf8)
        let terminal = try Terminal(
            remote,
            command: "printf '\\033[?2004h'; stty raw -echo; echo ready; head -c \(expected.count) | od -An -tx1 | tr -d ' \\n'; echo; sleep 2")
        let surface = terminal.surface
        try await surface.waitForScreen("ready")
        surface.paste("one\ntwo three")
        try await surface.waitForScreen(expected.map { String(format: "%02x", $0) }.joined())
        try await terminal.close()
    }

    // MARK: Failures and lifecycle

    @Test func aDroppedConnectionClosesTheTerminal() async throws {
        let terminal = try Terminal(.fake, command: "echo connected; sleep 30")
        try await terminal.surface.waitForScreen("connected")
        Servers.fake.dropAllConnections()
        try await terminal.surface.waitForClose()
        try await GhosttyTestHost.shared.waitUntil("the end") { terminal.ends.end != nil }
        #expect(terminal.ends.end == .connectionLost)
        try await terminal.surface.free()
    }

    @Test func aConnectionFailureIsShownAndEndsTheTerminal() async throws {
        let closedPort = try TestSSHD.freePort()
        let target = SSHTarget(host: "127.0.0.1", port: closedPort, username: NSUserName(), credentials: .automatic)
        let terminal = try Terminal(.fake, command: "true", waitAfterCommand: true, target: target)
        try await terminal.surface.waitForScreen("[relay] Couldn't open a terminal on 127.0.0.1")
        try await terminal.surface.waitForScreen("Process exited")
        try await GhosttyTestHost.shared.waitUntil("the error") { terminal.ends.error != nil }
        try await terminal.surface.free()
    }

    @Test func closingDuringAFloodTearsDownCleanly() async throws {
        let terminal = try Terminal(.fake, command: "echo flooding; yes")
        try await terminal.surface.waitForScreen("flooding")
        try await Task.sleep(for: .milliseconds(300))
        let pid = try #require(Servers.fake.sessions.last?.pid)
        try await terminal.close()
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) != 0)
        #expect(terminal.ends.end == .closedLocally)
    }

    @Test(arguments: Remote.allCases)
    func severalTerminalsShareOneConnection(remote: Remote) async throws {
        let (pool, target) = try Servers.endpoint(remote)
        let baseline = await pool.activeChannels(for: target).reduce(0, +)
        let terminals = try (0..<4).map { index in
            try Terminal(remote, command: "echo terminal-\(index)-up; sleep 30")
        }
        for (index, terminal) in terminals.enumerated() {
            try await terminal.surface.waitForScreen("terminal-\(index)-up")
        }
        #expect(await pool.activeChannels(for: target).reduce(0, +) == baseline + 4)
        #expect(await pool.activeChannels(for: target).count == 1)
        for terminal in terminals { try await terminal.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        while await pool.activeChannels(for: target).reduce(0, +) != baseline, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await pool.activeChannels(for: target).reduce(0, +) == baseline)
    }

    // MARK: Helpers

    static let tmuxPath: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func sha256(_ data: Data) -> String {
        let url = Servers.scratch.appendingPathComponent("sha-\(UUID().uuidString)")
        try? data.write(to: url)
        return String(run("/usr/bin/shasum", ["-a", "256", url.path]).prefix(64))
    }
}

}

final class EndLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _end: SSHTerminalEnd?
    private var _error: Error?
    func record(_ end: SSHTerminalEnd?, _ error: Error?) {
        lock.withLock {
            _end = end
            _error = error
        }
    }
    var end: SSHTerminalEnd? { lock.withLock { _end } }
    var error: Error? { lock.withLock { _error } }
}
