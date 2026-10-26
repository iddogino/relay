import AppKit
import Foundation
import GhosttyKit
import RelayTestSupport
import Testing
@testable import RelayGhosttyIO
@testable import RelaySSH

extension GhosttyIOSuites {
/// The end-to-end path against a real remote host: runs when
/// `RELAY_SSH_LIVE_HOST` is set (`user@host[:port]`), authenticating as
/// Relay would (ssh-agent, `~/.ssh/id_ed25519`) and verifying the host
/// against `~/.ssh/known_hosts`. tmux runs only on a private socket that
/// the test creates and kills, so no existing session is ever touched.
@Suite("Terminal over SSH (live host)", .serialized)
@MainActor
struct LiveTerminalTests {
    static let target: SSHTarget? = {
        guard let spec = ProcessInfo.processInfo.environment["RELAY_SSH_LIVE_HOST"], !spec.isEmpty else { return nil }
        let (user, hostPort) = spec.contains("@")
            ? (String(spec.split(separator: "@")[0]), String(spec.split(separator: "@")[1]))
            : (NSUserName(), spec)
        let parts = hostPort.split(separator: ":")
        let key = NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath
        return SSHTarget(host: String(parts[0]), port: parts.count > 1 ? Int(parts[1]) ?? 22 : 22,
                         username: user,
                         credentials: FileManager.default.fileExists(atPath: key) ? .keyFile(path: "~/.ssh/id_ed25519") : .automatic)
    }()

    static let pool = SSHConnectionPool()
    /// Where remote tools usually live, for non-login command shells.
    static let path = "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

    final class Terminal {
        let surface: TestSurface
        let link: SSHTerminalLink
        let ends = EndLog()

        @MainActor
        init(command: String?) throws {
            let io = ManualTerminalIO()
            surface = TestSurface(mode: .manual(io), captureIO: false)
            try #require(surface.surface != nil)
            let ends = ends
            link = SSHTerminalLink(
                io: io, pool: LiveTerminalTests.pool,
                configuration: .init(target: LiveTerminalTests.target!, command: command,
                                     environment: [("LANG", "en_US.UTF-8")]),
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

    @Test(.enabled(if: target != nil))
    func theLoginShellRoundTrips() async throws {
        let terminal = try Terminal(command: nil)
        // Whatever the user's prompt looks like: ask for a computed marker.
        try await Task.sleep(for: .seconds(1))
        terminal.typeLine("echo RELAY_LIVE_$((20+22))")
        try await terminal.surface.waitForScreen("RELAY_LIVE_42", timeout: .seconds(30))
        terminal.typeLine("exit")
        try await terminal.surface.waitForClose(timeout: .seconds(30))
        try await GhosttyTestHost.shared.waitUntil("the end") { terminal.ends.end != nil }
        #expect(terminal.ends.end == .exited(0))
        try await terminal.surface.free()
    }

    @Test(.enabled(if: target != nil))
    func theRemotePTYFollowsResizes() async throws {
        let terminal = try Terminal(
            command: "/bin/sh -c \"trap 'echo size \\$(stty size)' WINCH; echo start \\$(stty size); while :; do sleep 0.05; done\"")
        let surface = terminal.surface
        func remoteAgrees() async throws {
            try await GhosttyTestHost.shared.waitUntil("the remote size", timeout: .seconds(15), screen: { surface.screen }) {
                guard let grid = surface.gridSize else { return false }
                let lines = surface.allText.components(separatedBy: "\n").filter { $0.hasPrefix("start ") || $0.hasPrefix("size ") }
                return lines.last?.hasSuffix(" \(grid.rows) \(grid.columns)") ?? false
            }
        }
        try await remoteAgrees()
        for (width, height) in [(1100.0, 700.0), (520.0, 300.0), (900.0, 560.0)] {
            let before = surface.gridSize
            surface.setSize(width: width, height: height)
            try await GhosttyTestHost.shared.waitUntil("a new grid") { surface.gridSize != before }
            try await remoteAgrees()
        }
        try await terminal.close()
    }

    @Test(.enabled(if: target != nil))
    func tmuxOnAPrivateSocket() async throws {
        let socket = "relay-live-\(UUID().uuidString.prefix(8))"
        let terminal = try Terminal(command: "\(Self.path) exec tmux -L \(socket) -f /dev/null new-session -s live")
        let surface = terminal.surface
        do {
            try await surface.waitForScreen("[live]", timeout: .seconds(30))
            terminal.typeLine("echo tmux-live-$((40+2))")
            try await surface.waitForScreen("tmux-live-42", timeout: .seconds(15))
            let initial = try #require(surface.gridSize)
            surface.setSize(width: 1000, height: 640)
            try await GhosttyTestHost.shared.waitUntil("a new grid") { surface.gridSize != initial }
            let grown = try #require(surface.gridSize)
            try await GhosttyTestHost.shared.waitUntil("tmux to follow", timeout: .seconds(15)) {
                // tmux redraws its status line across the full new width.
                surface.screenLines.last?.count ?? 0 >= grown.columns - 2
            }
        } catch {
            _ = try? await Self.pool.exec(target: Self.target!, command: "\(Self.path) tmux -L \(socket) kill-server; rm -f \"${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/\(socket)\"",
                                          stdin: Data(), timeout: .seconds(15))
            throw error
        }
        let result = try await Self.pool.exec(target: Self.target!, command: "\(Self.path) tmux -L \(socket) kill-server; rm -f \"${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/\(socket)\"",
                                              stdin: Data(), timeout: .seconds(15))
        #expect(result.exitCode == 0)
        try await surface.waitForClose(timeout: .seconds(15))
        try await surface.free()
    }

    @Test(.enabled(if: target != nil))
    func outputIsRenderedOnScreen() async throws {
        let terminal = try Terminal(
            command: "printf '\\033[2J\\033[H\\033[41m%20s\\033[0m\\n\\033[44m%20s\\033[0m\\n' '' ''; echo RENDER-$((1+1)); sleep 30")
        let surface = terminal.surface
        try await surface.waitForScreen("RENDER-2", timeout: .seconds(30))
        func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool {
            p.map { Int($0.r) > Int($0.g) + 50 && Int($0.r) > Int($0.b) + 50 } ?? false
        }
        func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool {
            p.map { Int($0.b) > Int($0.r) + 30 && Int($0.b) > Int($0.g) + 10 } ?? false
        }
        try await GhosttyTestHost.shared.waitUntil("the bars to be drawn") {
            isRed(surface.renderedCell(column: 5, row: 0)) && isBlue(surface.renderedCell(column: 5, row: 1))
        }
        #expect(!isRed(surface.renderedCell(column: 25, row: 0)))
        try await terminal.close()
    }

    @Test(.enabled(if: target != nil))
    func vimWorks() async throws {
        let terminal = try Terminal(command: "vim -u NONE -i NONE -N -n")
        let surface = terminal.surface
        try await GhosttyTestHost.shared.waitUntil("vim to draw", timeout: .seconds(30), screen: { surface.screen }) {
            surface.screenLines.filter { $0.hasPrefix("~") }.count > 5
        }
        surface.typeKeys("ilive vim edit")
        surface.press(keycode: Key.escape)
        try await surface.waitForScreen("live vim edit")
        terminal.typeLine(":q!")
        try await surface.waitForClose(timeout: .seconds(15))
        try await surface.free()
    }

    @Test(.enabled(if: target != nil))
    func largeOutputOverTheNetwork() async throws {
        let terminal = try Terminal(command: "/bin/sh -c 'seq 1 300000; echo SEQ-$((1+1))-DONE; sleep 30'")
        let started = ContinuousClock.now
        try await terminal.surface.waitForScreen("SEQ-2-DONE", timeout: .seconds(120))
        print("[live] \(Self.target!.host): seq 1 300000 (≈2 MB) in \(ContinuousClock.now - started)")
        #expect(terminal.surface.allText.contains("\n299999\n300000\n"))
        try await terminal.close()
    }

    @Test(.enabled(if: target != nil))
    func typedInputArrivesIntact() async throws {
        let count = 2000
        let terminal = try Terminal(
            command: "stty raw -echo; echo ready; head -c \(count) | { command -v sha256sum >/dev/null && sha256sum || shasum -a 256; }; sleep 5")
        let surface = terminal.surface
        try await surface.waitForScreen("ready", timeout: .seconds(30))
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 -_=+.,/")
        var input = ""
        for i in 0..<count { input.append(alphabet[(i * 11 + i / 7) % alphabet.count]) }
        surface.typeKeys(input)
        try await surface.waitForScreen(TerminalOverSSHTests.sha256(Data(input.utf8)), timeout: .seconds(30))
        try await terminal.close()
    }

    // MARK: Everyday TUIs

    @Test(.enabled(if: target != nil))
    func lessScrollsWithTheWheel() async throws {
        let terminal = try Terminal(command: RealTUITests.lessCommand)
        try await RealTUITests.driveLess(terminal.surface)
        try await RealTUITests.expectModesRestored(terminal.surface)
        try await terminal.surface.waitForClose(timeout: .seconds(15))
        try await terminal.close()
    }

    @Test(.enabled(if: target != nil))
    func topRedrawsResizesAndQuits() async throws {
        let terminal = try Terminal(command: RealTUITests.topCommand)
        try await RealTUITests.driveTop(terminal.surface)
        try await RealTUITests.expectModesRestored(terminal.surface)
        try await terminal.surface.waitForClose(timeout: .seconds(15))
        try await terminal.close()
    }

    @Test(.enabled(if: target != nil))
    func vimTakesTheMouseAndPastes() async throws {
        let terminal = try Terminal(command: RealTUITests.vimCommand)
        try await RealTUITests.driveVim(terminal.surface)
        try await RealTUITests.expectModesRestored(terminal.surface)
        try await terminal.surface.waitForClose(timeout: .seconds(15))
        try await terminal.close()
    }

    // MARK: System monitors (where the live host has them)

    /// Whether the live host has an executable at `path`.
    static func liveHas(_ path: String) async -> Bool {
        guard let target else { return false }
        let result = try? await pool.exec(target: target, command: "test -x \(path)", stdin: Data(), timeout: .seconds(15))
        return result?.exitCode == 0
    }

    enum Transport: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case builtIn
        /// The system ssh in a local terminal: Relay's other path.
        case systemSSH
        var testDescription: String { rawValue }
    }

    /// `command` on the live host over `transport`, in a terminal that
    /// stays after it ends; and how to close it.
    func terminal(_ command: String, over transport: Transport) throws -> (surface: TestSurface, close: () async throws -> Void) {
        switch transport {
        case .builtIn:
            let io = ManualTerminalIO()
            let surface = TestSurface(mode: .manual(io), waitAfterCommand: true, captureIO: false)
            try #require(surface.surface != nil)
            let link = SSHTerminalLink(io: io, pool: Self.pool, configuration: .init(
                target: Self.target!, command: command, environment: [("LANG", "en_US.UTF-8")]))
            link.start()
            return (surface, { link.close(); try await surface.free() })
        case .systemSSH:
            let target = Self.target!
            let ssh = "/usr/bin/ssh -tt -o BatchMode=yes -p \(target.port) \(target.username)@\(target.host) "
                + TerminalProtocolTests.shellQuote(command)
            let surface = TestSurface(mode: .exec(command: "/usr/bin/env LANG=en_US.UTF-8 " + ssh), waitAfterCommand: true)
            try #require(surface.surface != nil)
            return (surface, { try await surface.free() })
        }
    }

    /// `program` (fresh home, `path`) inside tmux on a private socket, set
    /// up as Relay sets up its sessions; once tmux is gone, its exit status
    /// and the terminal's modes are reported (as `RealTUITests.command`
    /// does).
    static func inRelayTmuxCommand(_ program: String, path: String, socket: String) -> String {
        let inner = """
        trap '' INT; t=$(mktemp -d /tmp/relay-tui.XXXXXX); cd "$t"
        HOME="$t" PATH='\(path)' \(program); echo $? > "$1/status"; cd /; rm -rf "$t"
        """
        let probe = TerminalProtocolTests.probeCommand(["query"] + RealTUITests.modes.map { TerminalProtocolTests.hex($0.query) })
        let script = """
        d=$(mktemp -d /tmp/relay-tmux.XXXXXX); trap 'rm -rf "$d"' EXIT HUP TERM
        cat > "$d/conf" <<'CONF'
        set -s escape-time 10
        set -s focus-events on
        set -sa terminal-features ',xterm-256color:RGB'
        set -sa terminal-overrides ',xterm-256color:smcup@:rmcup@'
        set -g status off
        set -g mouse off
        set -g allow-passthrough on
        CONF
        printf '%s' '\(Data(inner.utf8).base64EncodedString())' | base64 -d > "$d/inner"
        PATH=/opt/homebrew/bin:/usr/local/bin:$PATH tmux -L \(socket) -f "$d/conf" new-session -s tui "sh $d/inner $d"
        rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/\(socket)"
        printf '\\033[0m\\033[H\\033[2J'; echo "TUI-EXIT=$(cat "$d/status" 2>/dev/null)"; PROBE_NOCLEAR=1 \(probe)
        """
        return "sh -c " + TerminalProtocolTests.shellQuote(script)
    }

    @Test(.enabled(if: target != nil), arguments: Transport.allCases)
    func htopDrawsResizesTakesClicksAndQuits(over transport: Transport) async throws {
        guard await Self.liveHas("/usr/bin/htop") else { return }
        // A fresh home, and no settings file at all (htop saves its settings
        // as it exits, even on a hangup).
        let (surface, close) = try terminal(RealTUITests.command("/usr/bin/htop", extraEnvironment: "HTOPRC=/dev/null", path: "/usr/bin:/bin"),
                                            over: transport)
        try await RealTUITests.driveHtop(surface)
        try await RealTUITests.expectModesRestored(surface)
        try await close()
    }

    @Test(.enabled(if: target != nil), arguments: Transport.allCases)
    func htopInTmux(over transport: Transport) async throws {
        guard await Self.liveHas("/usr/bin/htop") else { return }
        let socket = "relay-live-\(UUID().uuidString.prefix(8))"
        let (surface, close) = try terminal(Self.inRelayTmuxCommand("HTOPRC=/dev/null /usr/bin/htop", path: "/usr/bin:/bin", socket: socket),
                                            over: transport)
        do {
            try await RealTUITests.driveHtop(surface)
            try await RealTUITests.expectModesRestored(surface)
        } catch {
            try await killTmux(socket)
            throw error
        }
        try await close()
    }

    static let mactopPath = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin"

    @Test(.enabled(if: target != nil), arguments: Transport.allCases)
    func mactopDrawsResizesAndQuits(over transport: Transport) async throws {
        guard await Self.liveHas("/opt/homebrew/bin/mactop") else { return }
        let (surface, close) = try terminal(RealTUITests.command("mactop", path: Self.mactopPath), over: transport)
        try await RealTUITests.driveMactop(surface)
        try await RealTUITests.expectModesRestored(surface)
        try await close()
    }

    @Test(.enabled(if: target != nil), arguments: Transport.allCases)
    func mactopInTmux(over transport: Transport) async throws {
        guard await Self.liveHas("/opt/homebrew/bin/mactop") else { return }
        let socket = "relay-live-\(UUID().uuidString.prefix(8))"
        let (surface, close) = try terminal(Self.inRelayTmuxCommand("mactop", path: Self.mactopPath, socket: socket), over: transport)
        do {
            try await RealTUITests.driveMactop(surface)
            try await RealTUITests.expectModesRestored(surface)
        } catch {
            try await killTmux(socket)
            throw error
        }
        try await close()
    }

    // MARK: Coding agents

    /// The remote's own copy of `tool`, run like RealTUITests does locally
    /// (fresh home: the first-run screen, no account needed).
    static func agentCommand(_ tool: String, extraEnvironment: String = "", setup: String = "", cleanup: String = "") -> String {
        "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; c=$(command -v \(tool)) || exit 127; "
            + RealTUITests.command("\"$c\"", extraEnvironment: extraEnvironment, path: "\"$PATH\"",
                                 setup: setup, cleanup: cleanup)
    }

    /// The same inside tmux on a private socket, as Relay runs sessions
    /// (status line off, mouse left to the terminal).
    static func agentInTmuxCommand(_ tool: String, socket: String, extraEnvironment: String = "", setup: String = "",
                                   cleanup: String = "") -> String {
        let script = """
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; c=$(command -v \(tool)) || exit 127
        trap '' INT; t=$(mktemp -d /tmp/relay-tui.XXXXXX); trap 'cd /; rm -rf "$t"; exit 129' HUP TERM; cd "$t"; \(setup)
        HOME="$t" DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \(extraEnvironment) "$c"
        s=$?; \(cleanup)
        printf '\\033[0m\\033[H\\033[2J'; echo "TUI-EXIT=$s"; sleep 2; cd /; rm -rf "$t"
        """
        let encoded = Data(script.utf8).base64EncodedString()
        return "\(path) f=$(mktemp /tmp/relay-tui-run.XXXXXX) && printf %s \(encoded) | base64 -d > \"$f\" && "
            + "trap 'rm -f \"$f\"' EXIT HUP TERM; "
            + "tmux -L \(socket) -f /dev/null new-session -s tui \"sh $f\" \\; set status off \\; set mouse off; "
            + "rm -f \"$f\" \"${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/\(socket)\""
    }

    func killTmux(_ socket: String) async throws {
        _ = try? await Self.pool.exec(target: Self.target!, command: "\(Self.path) tmux -L \(socket) kill-server; rm -f \"${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/\(socket)\"",
                                      stdin: Data(), timeout: .seconds(15))
    }

    @Test(.enabled(if: target != nil))
    func claudeCode() async throws {
        let terminal = try Terminal(command: Self.agentCommand("claude"))
        try await RealTUITests.driveClaude(terminal.surface)
        try await RealTUITests.expectModesRestored(terminal.surface)
        try await terminal.surface.waitForClose(timeout: .seconds(15))
        try await terminal.close()
    }

    @Test(.enabled(if: target != nil))
    func codex() async throws {
        let terminal = try Terminal(command: Self.agentCommand("codex", extraEnvironment: "CODEX_HOME=\"$t\"", setup: RealTUITests.codexConfig,
                                                               cleanup: RealTUITests.stopCodexDaemon("\"$c\"", path: "\"$PATH\"")))
        try await RealTUITests.driveCodex(terminal.surface)
        try await RealTUITests.expectModesRestored(terminal.surface)
        try await terminal.surface.waitForClose(timeout: .seconds(15))
        try await terminal.close()
    }

    @Test(.enabled(if: target != nil))
    func claudeCodeInTmux() async throws {
        let socket = "relay-live-\(UUID().uuidString.prefix(8))"
        let terminal = try Terminal(command: Self.agentInTmuxCommand("claude", socket: socket))
        do {
            try await RealTUITests.driveClaude(terminal.surface)
            try await terminal.surface.waitForClose(timeout: .seconds(30))
        } catch {
            try await killTmux(socket)
            throw error
        }
        try await terminal.surface.free()
    }

    @Test(.enabled(if: target != nil))
    func codexInTmux() async throws {
        let socket = "relay-live-\(UUID().uuidString.prefix(8))"
        let terminal = try Terminal(command: Self.agentInTmuxCommand(
            "codex", socket: socket, extraEnvironment: "CODEX_HOME=\"$t\"", setup: RealTUITests.codexConfig,
            cleanup: RealTUITests.stopCodexDaemon("\"$c\"", path: "\"$PATH\"")))
        do {
            try await RealTUITests.driveCodex(terminal.surface)
            try await terminal.surface.waitForClose(timeout: .seconds(30))
        } catch {
            try await killTmux(socket)
            throw error
        }
        try await terminal.surface.free()
    }
}
}
