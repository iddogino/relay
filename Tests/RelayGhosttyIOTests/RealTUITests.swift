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
}
}
