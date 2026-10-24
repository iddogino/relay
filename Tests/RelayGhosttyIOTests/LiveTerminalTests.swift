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
}
}
