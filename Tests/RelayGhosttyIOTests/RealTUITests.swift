// macOS only: these run local programs and SSH servers.
#if os(macOS)
import AppKit
import Foundation
import GhosttyKit
import RelayTestSupport
import Testing
@testable import RelayGhosttyIO
@testable import RelaySSH

/// The coding agents people run in Relay, for real, over the built-in
/// client: Claude Code (Ink: synchronized output, focus and color-scheme
/// reports, bracketed paste, XTVERSION and kitty keyboard queries) and
/// Codex (ratatui/crossterm: cursor position and color queries it can't
/// start without, kitty keyboard flags, mouse capture, the alternate
/// screen). Each runs in a fresh home, so it shows its first-run screen and
/// needs no account; the test moves through the menu with the keyboard,
/// resizes, quits, and then checks the agent left the terminal's modes as
/// it found them.
///
/// Runs when the tools are found (`RELAY_TEST_CLAUDE` / `RELAY_TEST_CODEX`,
/// else on PATH or in ~/.local/bin); CI installs them and sets
/// `RELAY_TEST_REQUIRE_TUIS=1`, which makes a missing tool a failure.
extension GhosttyIOSuites {
@Suite("Real TUIs over SSH", .serialized)
@MainActor
struct RealTUITests {
    typealias Remote = TerminalOverSSHTests.Remote

    static let environment = ProcessInfo.processInfo.environment
    static let required = environment["RELAY_TEST_REQUIRE_TUIS"] == "1"

    static func find(_ name: String) -> String? {
        if let path = environment["RELAY_TEST_\(name.uppercased())"], !path.isEmpty { return path }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [NSString(string: "~/.local/bin").expandingTildeInPath]
        for directory in directories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
        }
        return nil
    }

    static let claude = find("claude")
    static let codex = find("codex")

    /// A PATH for the remote end that finds the tool and node (npm's
    /// launchers are node scripts).
    static var path: String {
        let directories = [claude, codex, find("node")].compactMap { $0 }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        return (directories + ["/usr/bin", "/bin"]).joined(separator: ":")
    }

    /// Terminal modes an agent may change and must restore on exit: each
    /// query, and the reply meaning "as before".
    static let modes: [(query: String, restored: String)] = [
        ("\u{1B}[?2004$p", "\u{1B}[?2004;2$y"),   // bracketed paste
        ("\u{1B}[?1004$p", "\u{1B}[?1004;2$y"),   // focus reports
        ("\u{1B}[?1000$p", "\u{1B}[?1000;2$y"),   // mouse
        ("\u{1B}[?1002$p", "\u{1B}[?1002;2$y"),
        ("\u{1B}[?1003$p", "\u{1B}[?1003;2$y"),
        ("\u{1B}[?1006$p", "\u{1B}[?1006;2$y"),
        ("\u{1B}[?1049$p", "\u{1B}[?1049;2$y"),   // alternate screen
        ("\u{1B}[?25$p", "\u{1B}[?25;1$y"),       // cursor visible
        ("\u{1B}[?u", "\u{1B}[?0u"),              // kitty keyboard flags
    ]

    /// Runs `program` (a shell word list) in a fresh home, then reports its
    /// exit status and the terminal's modes. Interrupts are ignored outside
    /// the program, so a Ctrl+C that arrives as it exits changes nothing.
    static func command(_ program: String, extraEnvironment: String = "", path: String? = nil, setup: String = "", cleanup: String = "") -> String {
        let probe = TerminalProtocolTests.probeCommand(["query"] + modes.map { TerminalProtocolTests.hex($0.query) })
        return """
        trap '' INT; t=$(mktemp -d /tmp/relay-tui.XXXXXX); trap 'cd /; rm -rf "$t"; exit 129' HUP TERM; cd "$t"; \(setup) \\
        HOME="$t" PATH=\(path ?? "'\(Self.path)'") CI= GITHUB_ACTIONS= DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 \\
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \(extraEnvironment) \(program); \\
        s=$?; \(cleanup) printf '\\033[0m\\033[H\\033[2J'; echo "TUI-EXIT=$s"; PROBE_NOCLEAR=1 \(probe); cd /; rm -rf "$t"
        """
    }

    /// The modes are back as the agent found them.
    static func expectModesRestored(_ surface: TestSurface, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await GhosttyTestHost.shared.waitUntil("the mode report", timeout: .seconds(60), screen: { surface.allText }) {
            surface.screenLines.contains { $0.trimmingCharacters(in: .whitespaces) == "END" }
        }
        let lines = surface.allText.components(separatedBy: "\n")
        for (index, mode) in modes.enumerated() {
            let hex = lines.filter { $0.hasPrefix("R\(index):") }.map { $0.dropFirst("R\(index):".count) }.joined()
                .trimmingCharacters(in: .whitespaces)
            #expect(hex == TerminalProtocolTests.hex(mode.restored),
                    "after exit, \(mode.query.debugDescription) → \(hex)", sourceLocation: sourceLocation)
        }
    }

    /// Codex starts a background app-server daemon (and an updater for it)
    /// that outlive the TUI: turned off in its fresh home's config, so
    /// nothing outlives the test.
    static let codexConfig = "printf '[features]\\ndaemon_auto_start = false\\n' > \"$t/config.toml\";"

    /// And stopped anyway, should one have started.
    static func stopCodexDaemon(_ codex: String, path: String) -> String {
        "HOME=\"$t\" CODEX_HOME=\"$t\" PATH=\(path) \(codex) app-server daemon stop >/dev/null 2>&1;"
    }

    // MARK: Drivers (shared with the live-host suite)

    static func screenHasLine(_ surface: TestSurface, _ predicate: @escaping (String) -> Bool) -> () -> Bool {
        { surface.screenLines.contains(where: predicate) }
    }

    /// Presses a key until the screen shows its effect: an app may still be
    /// starting up (and ignoring keys) when it first draws.
    static func press(_ surface: TestSurface, _ what: String, keycode: UInt32, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
                      unshifted: Character? = nil, until done: @escaping () -> Bool) async throws {
        for attempt in 0..<10 {
            surface.press(keycode: keycode, mods: mods, unshifted: unshifted)
            do {
                try await GhosttyTestHost.shared.waitUntil(what, timeout: .seconds(attempt == 9 ? 10 : 0.6), screen: { surface.allText }, done)
                return
            } catch where attempt < 9 {}
        }
    }

    /// Claude Code's first run: pick a theme with the arrow keys, resize,
    /// then quit with Ctrl+C twice.
    static func driveClaude(_ surface: TestSurface) async throws {
        let host = GhosttyTestHost.shared
        try await host.waitUntil("Claude Code's theme picker", timeout: .seconds(90), screen: { surface.allText }) {
            surface.allText.contains("Choose the text style")
        }
        try await host.waitUntil("the dark theme selected", screen: { surface.screen },
                                 screenHasLine(surface) { $0.contains("❯") && $0.contains("Dark mode") })
        try await press(surface, "the selection to move", keycode: Key.down,
                        until: screenHasLine(surface) { $0.contains("❯") && $0.contains("Light mode") && !$0.contains("colorblind") })
        surface.press(keycode: Key.up)
        try await host.waitUntil("the selection to move back", screen: { surface.screen },
                                 screenHasLine(surface) { $0.contains("❯") && $0.contains("Dark mode") && !$0.contains("colorblind") })
        // Narrower: Ink redraws for the new width.
        let before = surface.gridSize
        surface.setSize(width: 560, height: 420)
        try await host.waitUntil("a new grid") { surface.gridSize != before }
        try await host.waitUntil("a redraw at the new width", timeout: .seconds(15), screen: { surface.screen }) {
            surface.screen.contains("Choose the text style")
                && surface.screenLines.allSatisfy { $0.count <= (surface.gridSize?.columns ?? 0) }
        }
        // Ctrl+C twice in quick succession quits.
        for attempt in 0..<5 {
            surface.press(keycode: Key.c, mods: GHOSTTY_MODS_CTRL, unshifted: "c")
            try await host.pump(for: .milliseconds(100))
            surface.press(keycode: Key.c, mods: GHOSTTY_MODS_CTRL, unshifted: "c")
            do {
                try await host.waitUntil("Claude Code to quit", timeout: .seconds(2)) { surface.allText.contains("TUI-EXIT=") }
                break
            } catch where attempt < 4 {}
        }
        try await host.waitUntil("Claude Code to exit", timeout: .seconds(30), screen: { surface.allText }) {
            surface.allText.contains("TUI-EXIT=")
        }
    }

    /// Codex's first run: move through the sign-in choices, scroll the
    /// wheel at it (it captures the mouse), resize, then quit with Ctrl+C.
    static func driveCodex(_ surface: TestSurface) async throws {
        let host = GhosttyTestHost.shared
        try await host.waitUntil("Codex's welcome", timeout: .seconds(90), screen: { surface.allText }) {
            surface.screen.contains("Welcome to Codex")
        }
        try await host.waitUntil("the first choice selected", screen: { surface.screen },
                                 screenHasLine(surface) { $0.contains("> 1.") || $0.contains("› 1.") })
        try await press(surface, "the selection to move", keycode: Key.down,
                        until: screenHasLine(surface) { $0.contains("> 2.") || $0.contains("› 2.") })
        surface.moveMouse(column: 5, row: 5)
        surface.scroll(dy: 1)
        surface.scroll(dy: -1)
        surface.press(keycode: Key.up)
        try await host.waitUntil("the selection to move back", screen: { surface.screen },
                                 screenHasLine(surface) { $0.contains("> 1.") || $0.contains("› 1.") })
        let before = surface.gridSize
        surface.setSize(width: 600, height: 400)
        try await host.waitUntil("a new grid") { surface.gridSize != before }
        try await host.waitUntil("a redraw at the new size", timeout: .seconds(15), screen: { surface.screen }) {
            surface.screen.contains("Welcome to Codex")
                && surface.screenLines.allSatisfy { $0.count <= (surface.gridSize?.columns ?? 0) }
        }
        try await press(surface, "Codex to quit", keycode: Key.c, mods: GHOSTTY_MODS_CTRL, unshifted: "c") {
            !surface.screen.contains("Welcome to Codex")
        }
        try await host.waitUntil("Codex to exit", timeout: .seconds(30), screen: { surface.allText }) {
            surface.allText.contains("TUI-EXIT=")
        }
    }

    /// less over 500 numbered lines: the wheel (no mouse mode, alternate
    /// screen) turns into cursor keys that scroll it; q leaves it and the
    /// shell's screen as they were.
    static func driveLess(_ surface: TestSurface) async throws {
        let host = GhosttyTestHost.shared
        try await host.waitUntil("less to show the start", timeout: .seconds(30), screen: { surface.screen }) {
            surface.screenLines.first?.trimmingCharacters(in: .whitespaces) == "1"
        }
        surface.scroll(dy: -3)
        try await host.waitUntil("the wheel to scroll it", screen: { surface.screen }) {
            (Int(surface.screenLines.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 1) > 1
        }
        surface.scroll(dy: 10)
        try await host.waitUntil("the wheel to scroll back", screen: { surface.screen }) {
            surface.screenLines.first?.trimmingCharacters(in: .whitespaces) == "1"
        }
        surface.typeKeys("G")
        try await host.waitUntil("the end", screen: { surface.screen }) { surface.screen.contains("500") }
        surface.typeKeys("q")
        try await host.waitUntil("less to exit", timeout: .seconds(15), screen: { surface.allText }) {
            surface.allText.contains("TUI-EXIT=0")
        }
    }

    /// top: full-screen redraws every second; it follows a resize and quits.
    static func driveTop(_ surface: TestSurface) async throws {
        let host = GhosttyTestHost.shared
        try await host.waitUntil("top to draw", timeout: .seconds(30), screen: { surface.screen }) {
            surface.screen.contains("PID")
        }
        let before = surface.gridSize
        surface.setSize(width: 560, height: 360)
        try await host.waitUntil("a new grid") { surface.gridSize != before }
        try await host.waitUntil("a redraw at the new size", timeout: .seconds(15), screen: { surface.screen }) {
            surface.screen.contains("PID") && surface.screenLines.allSatisfy { $0.count <= (surface.gridSize?.columns ?? 0) }
        }
        for attempt in 0..<5 where !surface.allText.contains("TUI-EXIT=") {
            surface.typeKeys("q")
            try? await host.waitUntil("top to quit", timeout: .seconds(attempt == 4 ? 10 : 2)) { surface.allText.contains("TUI-EXIT=") }
        }
        #expect(surface.allText.contains("TUI-EXIT=0"))
    }

    /// vim with the mouse on: a click moves the cursor, the wheel scrolls,
    /// a paste in insert mode arrives bracketed (no auto-indent cascade).
    static func driveVim(_ surface: TestSurface) async throws {
        let host = GhosttyTestHost.shared
        try await host.waitUntil("vim to draw", timeout: .seconds(30), screen: { surface.screen }) {
            surface.screenLines.first?.hasPrefix("line 1") ?? false
        }
        surface.click(column: 3, row: 9)
        surface.typeKeys(":echo 'at '.line('.')")
        surface.press(keycode: Key.returnKey)
        try await surface.waitForScreen("at 10")
        surface.moveMouse(column: 3, row: 5)
        surface.scroll(dy: -3)
        try await host.waitUntil("the wheel to scroll", screen: { surface.screen }) {
            surface.screenLines.first.map { $0.hasPrefix("line ") && $0 != "line 1" } ?? false
        }
        surface.typeKeys("ggO")
        surface.paste("    pasted one\n    pasted two")
        surface.press(keycode: Key.escape)
        surface.typeKeys(":echo 'second='.getline(2)")
        surface.press(keycode: Key.returnKey)
        try await surface.waitForScreen("second=    pasted two")
        surface.typeKeys(":q!")
        surface.press(keycode: Key.returnKey)
        try await host.waitUntil("vim to exit", timeout: .seconds(15), screen: { surface.allText }) {
            surface.allText.contains("TUI-EXIT=0")
        }
    }

    /// The background behind a cell (its top-left corner, clear of the
    /// glyph).
    static func background(_ surface: TestSurface, column: Int, row: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let cell = surface.cellSize else { return nil }
        return surface.renderedPixel(x: column * cell.width + 1, y: row * cell.height + 1)
    }

    /// htop: it draws; a click on a column header sorts by it (the header
    /// highlight moves); a click on F1 in the function bar opens help;
    /// a resize redraws it; F10 quits.
    static func driveHtop(_ surface: TestSurface) async throws {
        let host = GhosttyTestHost.shared
        try await host.waitUntil("htop to draw", timeout: .seconds(30), screen: { surface.screen }) {
            surface.screen.contains("PID") && surface.screen.contains("F10Quit")
        }
        let lines = surface.screenLines
        let header = try #require(lines.firstIndex { $0.contains("PID") && $0.contains("MEM%") })
        let mem = try #require(lines[header].range(of: "MEM%")).lowerBound.utf16Offset(in: lines[header])
        let before = background(surface, column: mem + 1, row: header)
        surface.click(column: mem + 1, row: header)
        try await host.waitUntil("the sort column to move", screen: { "\(String(describing: before))" }) {
            guard let now = background(surface, column: mem + 1, row: header), let before else { return false }
            return now != before
        }
        let bar = try #require(surface.screenLines.lastIndex { $0.contains("F1Help") })
        let help = try #require(surface.screenLines[bar].range(of: "F1Help")).lowerBound.utf16Offset(in: surface.screenLines[bar])
        surface.click(column: help + 2, row: bar)
        try await host.waitUntil("htop's help", screen: { surface.screen }) { surface.screen.contains("CPU usage bar:") }
        // Any key leaves help (Enter: harmless in the main screen; a lone
        // Escape waits on htop's escape delay).
        for attempt in 0..<6 where !surface.screen.contains("F10Quit") {
            surface.press(keycode: attempt % 2 == 0 ? Key.returnKey : Key.escape)
            try? await host.waitUntil("back from help", timeout: .seconds(2)) { surface.screen.contains("F10Quit") }
        }
        try await host.waitUntil("back from help", screen: { surface.screen }) { surface.screen.contains("F10Quit") }
        let grid = surface.gridSize
        surface.setSize(width: 600, height: 400)
        try await host.waitUntil("a new grid") { surface.gridSize != grid }
        try await host.waitUntil("a redraw at the new size", timeout: .seconds(15), screen: { surface.screen }) {
            surface.screen.contains("PID") && surface.screenLines.allSatisfy { $0.count <= (surface.gridSize?.columns ?? 0) }
        }
        for attempt in 0..<5 where !surface.allText.contains("TUI-EXIT=") {
            surface.press(keycode: Key.f10)
            try? await host.waitUntil("htop to quit", timeout: .seconds(attempt == 4 ? 10 : 2)) { surface.allText.contains("TUI-EXIT=") }
        }
        try await host.waitUntil("htop's exit status", timeout: .seconds(15), screen: { surface.allText }) {
            surface.allText.contains("TUI-EXIT=0")
        }
    }

    /// mactop (Apple Silicon monitor, no sudo needed): it draws, redraws
    /// for a new size, and quits with q.
    static func driveMactop(_ surface: TestSurface) async throws {
        let host = GhosttyTestHost.shared
        try await host.waitUntil("mactop to draw", timeout: .seconds(30), screen: { surface.screen }) {
            surface.screen.contains("mactop") && surface.screen.contains("Process List")
        }
        let grid = surface.gridSize
        surface.setSize(width: 1000, height: 640)
        try await host.waitUntil("a new grid") { surface.gridSize != grid }
        try await host.waitUntil("a redraw at the new size", timeout: .seconds(15), screen: { surface.screen }) {
            guard let columns = surface.gridSize?.columns else { return false }
            // Its frame spans the new width.
            return surface.screenLines.contains { $0.hasPrefix("╭") && $0.count == columns }
        }
        for attempt in 0..<5 where !surface.allText.contains("TUI-EXIT=") {
            surface.typeKeys("q")
            try? await host.waitUntil("mactop to quit", timeout: .seconds(attempt == 4 ? 10 : 2)) { surface.allText.contains("TUI-EXIT=") }
        }
        try await host.waitUntil("mactop's exit status", timeout: .seconds(15), screen: { surface.allText }) {
            surface.allText.contains("TUI-EXIT=0")
        }
    }

    static let lessCommand = command("sh -c 'seq 1 500 | less'", extraEnvironment: "LESS= LESSOPEN= LESSKEY=/dev/null", path: "/usr/bin:/bin")
    static let topCommand = command("top", path: "/usr/bin:/bin")
    static let vimCommand = command(
        "vim -u NONE -i NONE -N -n -c 'set mouse=a ttymouse=sgr autoindent' -c 'call setline(1, map(range(1, 200), \"\\\"line \\\".v:val\"))'",
        path: "/usr/bin:/bin")

    // MARK: Tests
    // MARK: Tests

    @Test(.enabled(if: claude != nil || required), arguments: Remote.allCases)
    func claudeCode(remote: Remote) async throws {
        let claude = try #require(Self.claude, "claude not found")
        let terminal = try TerminalOverSSHTests.Terminal(remote, command: Self.command("'\(claude)'"), waitAfterCommand: true)
        try await Self.driveClaude(terminal.surface)
        try await Self.expectModesRestored(terminal.surface)
        // It cleans up after itself, then ends.
        try await GhosttyTestHost.shared.waitUntil("the end", timeout: .seconds(15)) { terminal.ends.end != nil }
        #expect(terminal.ends.end == .exited(0))
        try await terminal.close()
    }

    @Test(.enabled(if: codex != nil || required), arguments: Remote.allCases)
    func codex(remote: Remote) async throws {
        let codex = try #require(Self.codex, "codex not found")
        let terminal = try TerminalOverSSHTests.Terminal(
            remote, command: Self.command("'\(codex)'", extraEnvironment: "CODEX_HOME=\"$t\"", setup: Self.codexConfig,
                                          cleanup: Self.stopCodexDaemon("'\(codex)'", path: "'\(Self.path)'")),
            waitAfterCommand: true)
        try await Self.driveCodex(terminal.surface)
        try await Self.expectModesRestored(terminal.surface)
        // It cleans up after itself, then ends.
        try await GhosttyTestHost.shared.waitUntil("the end", timeout: .seconds(15)) { terminal.ends.end != nil }
        #expect(terminal.ends.end == .exited(0))
        try await terminal.close()
    }

    @Test(arguments: Remote.allCases)
    func lessScrollsWithTheWheel(remote: Remote) async throws {
        let terminal = try TerminalOverSSHTests.Terminal(remote, command: Self.lessCommand, waitAfterCommand: true)
        try await Self.driveLess(terminal.surface)
        try await Self.expectModesRestored(terminal.surface)
        try await terminal.close()
    }

    @Test(arguments: Remote.allCases)
    func topRedrawsResizesAndQuits(remote: Remote) async throws {
        let terminal = try TerminalOverSSHTests.Terminal(remote, command: Self.topCommand, waitAfterCommand: true)
        try await Self.driveTop(terminal.surface)
        try await Self.expectModesRestored(terminal.surface)
        try await terminal.close()
    }

    @Test(arguments: Remote.allCases)
    func vimTakesTheMouseAndPastes(remote: Remote) async throws {
        let terminal = try TerminalOverSSHTests.Terminal(remote, command: Self.vimCommand, waitAfterCommand: true)
        try await Self.driveVim(terminal.surface)
        try await Self.expectModesRestored(terminal.surface)
        try await terminal.close()
    }
}
}

#endif
