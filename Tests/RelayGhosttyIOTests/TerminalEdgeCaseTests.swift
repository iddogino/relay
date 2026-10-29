// macOS only: these run local programs and SSH servers.
#if os(macOS)
import AppKit
import Foundation
import GhosttyKit
import RelayTestSupport
import Testing
@testable import RelayGhosttyIO
@testable import RelaySSH

/// The protocol parity suite, continued: the remote pty itself (its modes,
/// line discipline, signals and size), character widths, reports the
/// terminal makes on its own (in-band resize, color scheme), output split
/// at every byte, and tmux as Relay runs it. Same method: each scenario
/// runs locally (the reference) and over the built-in client.
private typealias LiveTerminalTests = GhosttyIOSuites.LiveTerminalTests
private typealias TerminalOverSSHTests = GhosttyIOSuites.TerminalOverSSHTests

extension GhosttyIOSuites.TerminalProtocolTests {
    // MARK: The remote pty

    /// The system ssh to `path`'s server, run in a local terminal as
    /// Relay's other path runs it.
    static func systemSSH(_ path: Path, _ command: String) throws -> String {
        if path == .live, let target = LiveTerminalTests.target {
            return "/usr/bin/ssh -tt -o BatchMode=yes -p \(target.port) \(target.username)@\(target.host) " + shellQuote(command)
        }
        guard case .success(let sshd) = TerminalOverSSHTests.Servers.sshd else { throw TestSSHD.StartError.unavailable("sshd") }
        return "/usr/bin/ssh -tt -F /dev/null -o IdentitiesOnly=yes -i \(sshd.clientKeyPath) -o UserKnownHostsFile=\(sshd.knownHostsPath) "
            + "-o StrictHostKeyChecking=yes -o 'SendEnv=LANG' -p \(sshd.port) \(NSUserName())@127.0.0.1 " + shellQuote(command)
    }

    @Test func theRemotePTYIsSetUpAsTheSystemSSHSetsItUp() async throws {
        // OpenSSH sends its local tty's modes; the built-in client sends
        // the same set, so a Linux server's pty (whose defaults differ from
        // macOS's) ends up the same either way.
        for path in Self.remotes where path != .fake {
            let builtIn = try Probe(path, ["termios"])
            try await builtIn.waitFor("END")
            let system = TestSurface(mode: .exec(command: "/usr/bin/env LANG=en_US.UTF-8 " + (try Self.systemSSH(path, Self.probeCommand(["termios"])))),
                                     waitAfterCommand: true)
            try await system.waitForScreen("END", timeout: .seconds(30))
            func report(_ text: String) -> [String] {
                text.components(separatedBy: "\n").filter {
                    $0.hasPrefix("TIOS:") || $0.hasPrefix("ENV:TERM=") || $0.hasPrefix("ENV:LANG=")
                }
            }
            let reference = report(system.allText)
            #expect(reference.count > 10, "\(path): \(system.allText)")
            #expect(report(builtIn.surface.allText) == reference, "\(path)")
            #expect(reference.contains("ENV:TERM=xterm-256color"), "\(path)")
            try await builtIn.close()
            try await system.free()
        }
    }

    /// What `cooked` reported: lines read, signals, end of file. (Echoed
    /// keys can precede a report on its line: "^CSIG:INT".)
    func cookedReport(_ probe: Probe) -> [String] {
        probe.surface.allText.components(separatedBy: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "LINE:") {
                let hex = Array(line[range.upperBound...].utf8)
                let bytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap {
                    UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)
                }
                return "LINE:" + String(decoding: bytes, as: UTF8.self).debugDescription
            }
            // (A window change can come as the program starts, as the
            // terminal settles on its first size.)
            if let range = line.range(of: "SIG:"), !line.hasSuffix("SIG:WINCH") { return String(line[range.lowerBound...]) }
            return line.hasSuffix("EOF") ? "EOF" : nil
        }
    }

    @Test func lineEditingAndSignalsWorkAsLocally() async throws {
        // A program reading lines (a shell's `read`, a password prompt) and
        // the keys the line discipline acts on: erase (a whole UTF-8
        // character: IUTF8), word erase, kill, ^C, ^\, ^Z, ^D.
        // One at a time: each terminal gets its keys while it's the one
        // being typed in.
        var probes: [Path: Probe] = [:]
        for path in Self.paths {
            let probe = try Probe(path, ["cooked", "30"])
            probes[path] = probe
            try await probe.waitFor("READY")
            let s = probe.surface
            let host = GhosttyTestHost.shared
            s.typeKeys("abx")
            s.press(keycode: Key.backspace)
            s.typeKeys("c")
            s.press(keycode: Key.returnKey)
            s.type("aé")
            s.press(keycode: Key.backspace)
            s.press(keycode: Key.returnKey)
            s.typeKeys("one two")
            s.press(keycode: Key.w, mods: GHOSTTY_MODS_CTRL, unshifted: "w")
            s.press(keycode: Key.returnKey)
            s.typeKeys("junk")
            s.press(keycode: Key.u, mods: GHOSTTY_MODS_CTRL, unshifted: "u")
            s.typeKeys("kept")
            s.press(keycode: Key.returnKey)
            for (key, character) in [(Key.c, "c"), (Key.backslash, "\\"), (Key.z, "z"), (Key.d, "d")] {
                try await host.pump(for: .milliseconds(300))
                s.press(keycode: key, mods: GHOSTTY_MODS_CTRL, unshifted: Character(character))
            }
            try await host.pump(for: .milliseconds(300))
            s.typeKeys("quit")
            s.press(keycode: Key.returnKey)
            try await probe.waitFor("END")
        }
        for probe in probes.values { try await probe.waitFor("END") }
        let reference = cookedReport(probes[.local]!)
        #expect(reference == ["LINE:\"abc\\n\"", "LINE:\"a\\n\"", "LINE:\"one \\n\"", "LINE:\"kept\\n\"",
                              "SIG:INT", "SIG:QUIT", "SIG:TSTP", "EOF", "LINE:\"quit\\n\""])
        for path in Self.remotes {
            #expect(cookedReport(probes[path]!) == reference, "\(path)")
        }
        try await closeAll(probes)
    }

    @Test func aPasswordPromptDoesNotShowWhatIsTyped() async throws {
        var probes: [Path: Probe] = [:]
        for path in Self.paths {
            let probe = try Probe(path, ["cooked", "20", "noecho"])
            probes[path] = probe
            try await probe.waitFor("READY")
            probe.surface.typeKeys("hunter2 secret")
            probe.surface.press(keycode: Key.returnKey)
            probe.surface.typeKeys("quit")
            probe.surface.press(keycode: Key.returnKey)
        }
        for (path, probe) in probes {
            try await probe.waitFor("END")
            #expect(cookedReport(probe).first == "LINE:\"hunter2 secret\\n\"", "\(path)")
            #expect(!probe.surface.allText.contains("hunter2"), "\(path): \(probe.surface.allText)")
        }
        try await closeAll(probes)
    }

    @Test func windowSizeChangesReachTheProgram() async throws {
        // Rapid resizes, a font size change (a new grid in the same view)
        // and a view too small for one cell: the program's view of its size
        // (TIOCGWINSZ, pixels too, which image tools size by) follows each.
        var probes: [Path: Probe] = [:]
        for path in Self.paths {
            let probe = try Probe(path, ["winsize", "60"])
            probes[path] = probe
            try await probe.waitFor("READY")
        }
        func lastSize(_ probe: Probe) -> String? {
            probe.surface.allText.components(separatedBy: "\n").last { $0.hasPrefix("WS:") }
                .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        }
        func expected(_ probe: Probe) -> String? {
            probe.surface.gridSize.map { "\($0.rows),\($0.columns),\($0.widthPx),\($0.heightPx)" }
        }
        let steps: [(String, (TestSurface) -> Void)] = [
            ("three quick resizes", { s in
                s.setSize(width: 1000, height: 600)
                s.setSize(width: 640, height: 400)
                s.setSize(width: 900, height: 500)
            }),
            ("a bigger font", { s in s.perform("increase_font_size:3") }),
            ("a view smaller than a cell", { s in s.setSize(width: 1, height: 1) }),
            ("back to normal", { s in
                s.perform("reset_font_size")
                s.setSize(width: 800, height: 480)
            }),
        ]
        for (what, step) in steps {
            for probe in probes.values { step(probe.surface) }
            for (path, probe) in probes {
                try await GhosttyTestHost.shared.waitUntil("\(path): the program sees \(what)", screen: { probe.surface.allText }) {
                    expected(probe) != nil && lastSize(probe) == expected(probe)
                }
            }
            let reference = lastSize(probes[.local]!)
            for path in Self.remotes { #expect(lastSize(probes[path]!) == reference, "\(path) after \(what)") }
        }
        for probe in probes.values { probe.surface.typeKeys("q") }
        for probe in probes.values { try await probe.waitFor("END") }
        try await closeAll(probes)
    }

    // MARK: Widths and reports

    /// Text, and the column the cursor ends at after it (from column 1):
    /// what TUIs (Ink, ratatui) assume when they lay out a screen.
    static let widths: [(name: String, bytes: [UInt8], column: Int)] = [
        ("CJK", Array("日本".utf8), 5),
        ("emoji", Array("👍".utf8), 3),
        ("ZWJ family", Array("👨‍👩‍👧".utf8), 3),
        ("flag", Array("🇯🇵".utf8), 3),
        ("combining mark", Array("e\u{301}x".utf8), 3),
        ("emoji presentation selector", Array("❤\u{FE0F}".utf8), 3),
        ("text presentation", Array("❤".utf8), 2),
        ("skin tone", Array("👋🏽".utf8), 3),
        ("Devanagari cluster", Array("क्षि".utf8), 3),
        ("zero-width space", Array("\u{200B}z".utf8), 2),
        ("halfwidth katakana", Array("ｱ".utf8), 2),
        ("NUL", [0x61, 0x00, 0x62], 3),
    ]

    @Test func charactersTakeTheCellsTUIsExpect() async throws {
        var queries = Self.widths.map { Self.hex(Data("\u{1B}[H\u{1B}[2K".utf8) + Data($0.bytes) + Data("\u{1B}[6n".utf8)) }
        // A long line wraps; with autowrap off it stops at the margin;
        // without grapheme clustering (2027) a ZWJ sequence is its parts.
        queries.append(Self.hex("\u{1B}[H\u{1B}[2J" + String(repeating: "w", count: 250) + "\u{1B}[6n"))
        queries.append(Self.hex("\u{1B}[?7l\u{1B}[H\u{1B}[2J" + String(repeating: "w", count: 250) + "\u{1B}[6n\u{1B}[?7h"))
        queries.append(Self.hex("\u{1B}[?2027l\u{1B}[H\u{1B}[2K👨‍👩‍👧\u{1B}[6n\u{1B}[?2027h"))
        let probes = try await runEverywhere(["query"] + queries, timeout: .seconds(120))
        let columns = try #require(probes[.local]!.surface.gridSize?.columns)
        for (index, width) in Self.widths.enumerated() {
            let reply = text(expectParity(probes, tag: "R\(index)", width.name))
            #expect(reply == "\u{1B}[1;\(width.column)R", "\(width.name): \(reply.debugDescription)")
        }
        let n = Self.widths.count
        #expect(text(expectParity(probes, tag: "R\(n)", "wrapping")) == "\u{1B}[\(1 + 250 / columns);\(250 % columns + 1)R")
        #expect(text(expectParity(probes, tag: "R\(n + 1)", "autowrap off")) == "\u{1B}[1;\(columns)R")
        #expect(text(expectParity(probes, tag: "R\(n + 2)", "no grapheme clustering")) == "\u{1B}[1;7R")
        try await closeAll(probes)
    }

    @Test func inBandResizeReportsFollowTheSize() async throws {
        // Mode 2048: the terminal reports each new size in-band, which
        // ordering with SIGWINCH can't garble (neovim, kitty-aware apps).
        let probes = try await recordEverywhere(setup: "\u{1B}[?2048h", teardown: "\u{1B}[?2048l") { surface in
            let before = surface.gridSize
            surface.setSize(width: 1000, height: 600)
            try await GhosttyTestHost.shared.waitUntil("a new grid") { surface.gridSize != before }
        }
        // The last report is the new size: rows, columns, then the text
        // area in pixels (whole cells). (A report before the resize can
        // differ: a fast program can start before the terminal has settled
        // on its first size.)
        let grid = try #require(probes[.local]!.surface.gridSize)
        let cell = try #require(probes[.local]!.surface.cellSize)
        let expected = "\u{1B}[48;\(grid.rows);\(grid.columns);\(grid.rows * cell.height);\(grid.columns * cell.width)t"
        for (path, probe) in probes {
            let got = text(probe.bytes("GOT"))
            #expect(got.hasSuffix(expected), "\(path): \(got.debugDescription)")
        }
        try await closeAll(probes)
    }

    @Test func colorSchemeChangesAreReported() async throws {
        // Mode 2031: the system switching dark/light is reported, so agents
        // re-theme (Claude Code asks for it).
        let probes = try await recordEverywhere(setup: "\u{1B}[?2031h", teardown: "\u{1B}[?2031l") { surface in
            guard let raw = surface.surface else { return }
            ghostty_surface_set_color_scheme(raw, GHOSTTY_COLOR_SCHEME_DARK)
            try await GhosttyTestHost.shared.pump(for: .milliseconds(100))
            ghostty_surface_set_color_scheme(raw, GHOSTTY_COLOR_SCHEME_LIGHT)
        }
        let got = text(expectParity(probes, "color scheme reports"))
        #expect(got.hasPrefix("\u{1B}[?997;"), "\(got.debugDescription)")
        try await closeAll(probes)
    }

    // MARK: Output split anywhere

    /// A fake server that sends the program's output in packets of `size`
    /// bytes: characters and escape sequences arrive in pieces.
    @MainActor
    enum Fragmenting {
        static func endpoint(_ size: Int) throws -> (FakeSSHServer, SSHConnectionPool) {
            var faults = FakeSSHServer.Faults()
            faults.fragmentOutput = size
            let server = try FakeSSHServer(faults: faults)
            var options = SSHConnectionPool.Options()
            options.knownHostsFiles = [try server.writeKnownHosts(in: TerminalOverSSHTests.Servers.scratch)]
            options.agent = nil
            options.defaultKeyFiles = []
            return (server, SSHConnectionPool(options: options))
        }
    }

    static let richOutput: String = {
        let copy = Data("split copy ✓ 日本語".utf8).base64EncodedString()
        return "\u{1B}[H\u{1B}[2J"
            + "plain ünïcödé 日本語 👨‍👩‍👧 e\u{301} ❤\u{FE0F} 🇯🇵\r\n"
            + "\u{1B}[48;2;200;30;40m      \u{1B}[0m truecolor\r\n"
            + "\u{1B}[38;5;46mgreen\u{1B}[0m \u{1B}[1;3;4:3;58:2::0:255:0mstyled\u{1B}[0m\r\n"
            + "\u{1B}]8;id=l;https://example.com/ü\u{1B}\\link\u{1B}]8;;\u{1B}\\ after\r\n"
            + "\u{1B}]2;split title ✓\u{07}"
            + "\u{1B}]52;c;\(copy)\u{1B}\\"
            + "\u{1B}[?2026h\u{1B}[6;1Hsynchronized row\u{1B}[?2026l\r\n"
            + "\u{1B}[8;1H" + String(repeating: "wrap", count: 40) + "\r\n"
            + "nul\u{0}byte \u{1B}[31mred\u{1B}[39m done\r\n"
    }()

    @Test(arguments: [1, 5])
    func outputSplitAnywhereRendersTheSame(packetSize: Int) async throws {
        // SSH packets can split a UTF-8 character, an escape sequence, an
        // OSC 52 payload anywhere; the terminal must see one stream.
        let (server, pool) = try Fragmenting.endpoint(packetSize)
        defer { server.shutdown() }
        let reference = try Probe(.local, ["emit", Self.hex(Self.richOutput), "1"])
        let split = try Probe(.fake, ["emit", Self.hex(Self.richOutput), "1"], endpoint: (pool, server.target))
        for probe in [reference, split] {
            try await probe.waitFor("END")
            try await GhosttyTestHost.shared.waitUntil("the clipboard write") { !probe.surface.clipboardWrites.isEmpty }
        }
        // Everything the program wrote (not what follows its exit, which
        // either may or may not show yet).
        func output(_ probe: Probe) -> String { probe.surface.allText.components(separatedBy: "\nEND").first ?? "" }
        #expect(output(split) == output(reference), "\(output(split).debugDescription) — locally: \(output(reference).debugDescription)")
        #expect(split.surface.clipboardWrites == ["split copy ✓ 日本語"])
        #expect(split.surface.actions.filter { $0.hasPrefix("title:") } == reference.surface.actions.filter { $0.hasPrefix("title:") })
        #expect(split.surface.actions.contains("title:split title ✓"))
        // The truecolor background, drawn.
        try await GhosttyTestHost.shared.waitUntil("the colored cells") {
            isColor(split.surface.renderedCell(column: 2, row: 1), 200, 30, 40)
        }
        #expect(server.sessions.first.map { $0.outputBytes >= Self.richOutput.utf8.count } == true)
        try await reference.close()
        try await split.close()
    }

    @Test func repliesToQueriesSplitAnywhereMatch() async throws {
        let queries = ["\u{1B}[c", "\u{1B}]11;?\u{1B}\\", "\u{1B}P$qm\u{1B}\\", "\u{1B}P+q436f\u{1B}\\",
                       "\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\", "\u{1B}[H👨‍👩‍👧\u{1B}[6n", "\u{1B}[?2026$p"]
        let (server, pool) = try Fragmenting.endpoint(1)
        defer { server.shutdown() }
        let arguments = ["query"] + queries.map { Self.hex($0) }
        let probes: [Path: Probe] = [.local: try Probe(.local, arguments), .fake: try Probe(.fake, arguments, endpoint: (pool, server.target))]
        for probe in probes.values { try await probe.waitFor("END", timeout: .seconds(60)) }
        for index in queries.indices {
            let reference = probes[.local]!.bytes("R\(index)")
            #expect(!reference.isEmpty, "\(queries[index].debugDescription)")
            #expect(probes[.fake]!.bytes("R\(index)") == reference, "\(queries[index].debugDescription)")
        }
        try await closeAll(probes)
    }

    // MARK: tmux, as Relay runs it

    /// `inner` (a shell command) in tmux on a private socket, set up as
    /// Relay sets up its sessions (SSHTmuxScripts: server options when the
    /// server is Relay's own, then the session's).
    static func inRelayTmux(_ inner: String, socket: String) -> String {
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
        set -g set-titles on
        set -g set-titles-string '#T'
        CONF
        printf '%s' '\(Data(inner.utf8).base64EncodedString())' | base64 -d > "$d/inner"
        PATH=/opt/homebrew/bin:/usr/local/bin:$PATH tmux -L \(socket) -f "$d/conf" new-session -s t "sh $d/inner; sleep 600"
        """
        return "sh -c " + shellQuote(script)
    }

    /// Ends a tmux server the test started, wherever it runs.
    func killTmux(_ socket: String, on path: Path) async {
        let command = "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH tmux -L \(socket) kill-server 2>/dev/null; "
            + "rm -f \"${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/\(socket)\""
        if path == .live, let target = LiveTerminalTests.target {
            _ = try? await LiveTerminalTests.pool.exec(target: target, command: command, stdin: Data(), timeout: .seconds(15))
        } else {
            TerminalOverSSHTests.run("/bin/sh", ["-c", command])
        }
    }

    /// Runs `inner` in Relay's tmux on every path; `drive` gets each once
    /// the probe has printed `marker` (READY: listening, END: done), and
    /// `check` each once it's done — while tmux still shows its screen.
    func inRelayTmuxEverywhere(_ inner: String, waitFor marker: String,
                               drive: (Path, TestSurface) async throws -> Void = { _, _ in },
                               check: (Path, Probe) async throws -> Void) async throws {
        var probes: [Path: Probe] = [:]
        var sockets: [Path: String] = [:]
        do {
            for path in Self.paths {
                let socket = "relay-e2e-\(UUID().uuidString.prefix(8))"
                sockets[path] = socket
                probes[path] = try Probe(path, [], command: Self.inRelayTmux(inner, socket: socket))
            }
            for (path, probe) in probes {
                try await probe.waitFor(marker, timeout: .seconds(45))
                try await GhosttyTestHost.shared.pump(for: .milliseconds(200))
                try await drive(path, probe.surface)
            }
            for (path, probe) in probes {
                try await probe.waitFor("END", timeout: .seconds(45))
                try await check(path, probe)
            }
        } catch {
            for (path, socket) in sockets { await killTmux(socket, on: path) }
            try await closeAll(probes)
            throw error
        }
        for (path, socket) in sockets { await killTmux(socket, on: path) }
        try await closeAll(probes)
    }

    @Test func relaysTmuxPassesWhatAgentsUse() async throws {
        // Through tmux configured as Relay configures it: the replies tmux
        // gives (it answers for the terminal), focus and mouse reports
        // (tmux's mouse is off, so a program's own mouse mode reaches the
        // terminal), bracketed paste. (Not Shift+Enter: with tmux's
        // extended-keys off it arrives as a plain Enter once a program has
        // turned such modes on, on every path alike.)
        let queries = ["\u{1B}[c", "\u{1B}[?2026$p", "\u{1B}[5;9H\u{1B}[6n", "\u{1B}]11;?\u{1B}\\", "\u{1B}[18t"]
        try await inRelayTmuxEverywhere(Self.probeCommand(["query"] + queries.map { Self.hex($0) }), waitFor: "END") { path, probe in
            let grid = try #require(probe.surface.gridSize)
            #expect(text(probe.bytes("R0")).hasPrefix("\u{1B}[?"), "\(path)")
            // A recent tmux answers for synchronized output (3.8 does, 3.4
            // doesn't: a live host may run an older one).
            if path != .live { #expect(text(probe.bytes("R1")).hasPrefix("\u{1B}[?2026;"), "\(path)") }
            #expect(text(probe.bytes("R2")) == "\u{1B}[5;9R", "\(path)")
            #expect(text(probe.bytes("R3")).hasPrefix("\u{1B}]11;rgb:"), "\(path)")
            #expect(text(probe.bytes("R4")) == "\u{1B}[8;\(grid.rows);\(grid.columns)t", "\(path)")
        }

        let setup = "\u{1B}[?1004h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h"
        let teardown = "\u{1B}[?1004l\u{1B}[?1000l\u{1B}[?1006l\u{1B}[?2004l"
        try await inRelayTmuxEverywhere(
            Self.probeCommand(["record", Self.hex(setup), Self.hex(teardown), "1.5"]), waitFor: "READY", drive: { _, surface in
            surface.setFocus(false)
            try await GhosttyTestHost.shared.pump(for: .milliseconds(200))
            surface.setFocus(true)
            try await GhosttyTestHost.shared.pump(for: .milliseconds(200))
            surface.click(column: 10, row: 5)
            try await GhosttyTestHost.shared.pump(for: .milliseconds(200))
            surface.paste("pasted ✓\nline 2")
        }) { path, probe in
            let got = text(probe.bytes("GOT"))
            for expected in ["\u{1B}[O\u{1B}[I", "\u{1B}[<0;11;6M", "\u{1B}[<0;11;6m", "\u{1B}[200~pasted ✓\nline 2\u{1B}[201~"] {
                #expect(got.contains(expected), "\(path): missing \(expected.debugDescription) in \(got.debugDescription)")
            }
        }
    }

    @Test func relaysTmuxPassesCopiesTitlesAndColors() async throws {
        // OSC 52 wrapped for tmux's passthrough (raw OSC 52 tmux keeps:
        // its set-clipboard is left at "external"), the title (tmux's
        // set-titles) and truecolor (the RGB feature Relay turns on).
        let copy = Data("copied through tmux ✓".utf8).base64EncodedString()
        let sequences = [
            "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;\(copy)\u{1B}\u{1B}\\\u{1B}\\",
            "\u{1B}]2;tmux title ✓\u{07}",
            "\u{1B}[H\u{1B}[2J\u{1B}[48;2;200;30;40m        \u{1B}[0m\r\n",
        ]
        try await inRelayTmuxEverywhere(
            Self.probeCommand(["emitseq", "0.3"] + sequences.map { Self.hex($0) }), waitFor: "END") { path, probe in
            let surface = probe.surface
            try await GhosttyTestHost.shared.waitUntil("\(path): the copy, title and colors", screen: { "\(surface.clipboardWrites) \(surface.actions)" }) {
                surface.clipboardWrites.contains("copied through tmux ✓") && surface.actions.contains("title:tmux title ✓")
                    && (0..<3).contains { isColor(surface.renderedCell(column: 3, row: $0), 200, 30, 40) }
            }
        }
    }
}

#endif
