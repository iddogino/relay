import AppKit
import CryptoKit
import Foundation
import GhosttyKit
import RelayTestSupport
import Testing
@testable import RelayGhosttyIO
@testable import RelaySSH

/// Everything a terminal does beyond plain text, through the whole path:
/// replies to queries, mouse and focus reports, keyboard protocols,
/// pastes, the clipboard, images, titles and notifications. A probe
/// program (Fixtures/term_probe.py) records exactly what the terminal
/// sends it, and each scenario runs three ways: locally in an exec surface
/// (the reference: what Relay does when the system ssh carries the
/// terminal, byte for byte the same terminal), and over the built-in
/// client to the in-process fake server and to a real sshd. The built-in
/// path must be indistinguishable from the reference — and the reference
/// must say what the protocol says, so both can't be wrong together.
extension GhosttyIOSuites {
@Suite("Terminal protocol parity", .serialized)
@MainActor
struct TerminalProtocolTests {
    enum Path: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case local
        case fake
        case sshd
        /// The live host, when `RELAY_SSH_LIVE_HOST` names one.
        case live
        var testDescription: String { rawValue }
    }

    static let paths: [Path] = [.local, .fake, .sshd] + (LiveTerminalTests.target != nil ? [.live] : [])
    static let remotes = paths.filter { $0 != .local }

    static let probeSource: String = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/term_probe.py")
        return try! String(contentsOf: url, encoding: .utf8)
    }()

    /// A shell command line running the probe with `arguments` (no files
    /// needed on the remote end).
    static func probeCommand(_ arguments: [String]) -> String {
        let encoded = Data(probeSource.utf8).base64EncodedString()
        return "python3 -c 'import base64;exec(base64.b64decode(\"\(encoded)\"))' "
            + arguments.map { "'\($0)'" }.joined(separator: " ")
    }

    static func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func hex(_ string: String) -> String { hex(Data(string.utf8)) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The probe running in a terminal on the test host.
    final class Probe {
        let path: Path
        let surface: TestSurface
        let link: SSHTerminalLink?

        /// The probe with `arguments`, or `command` (a shell command line)
        /// instead; `endpoint` replaces the path's server.
        @MainActor
        init(_ path: Path, _ arguments: [String], command: String? = nil, width: Double = 800, height: Double = 480,
             endpoint: (SSHConnectionPool, SSHTarget)? = nil, before: (TestSurface) -> Void = { _ in }) throws {
            self.path = path
            let custom = command != nil
            let command = command ?? TerminalProtocolTests.probeCommand(arguments)
            switch path {
            case .local:
                // libghostty runs a command as `exec -l <command>`: a shell
                // runs anything more than one program.
                let local = custom ? "/bin/sh -c " + TerminalProtocolTests.shellQuote(command) : command
                surface = TestSurface(mode: .exec(command: local), width: width, height: height, waitAfterCommand: true)
                link = nil
                before(surface)
            case .fake, .sshd, .live:
                let (pool, target) = try endpoint ?? (path == .live
                    ? (LiveTerminalTests.pool, LiveTerminalTests.target!)
                    : TerminalOverSSHTests.Servers.endpoint(path == .fake ? .fake : .sshd))
                let io = ManualTerminalIO()
                surface = TestSurface(mode: .manual(io), width: width, height: height, waitAfterCommand: true, captureIO: false)
                before(surface)
                link = SSHTerminalLink(
                    io: io, pool: pool,
                    configuration: .init(target: target, command: command, environment: [("LANG", "en_US.UTF-8")]),
                    onEnd: { _, _ in })
                link?.start()
            }
            try #require(surface.surface != nil)
            Probe.open[ObjectIdentifier(self)] = self
        }

        /// Probes not yet closed: a test that failed midway leaves its own,
        /// closed before the next test starts.
        @MainActor static var open: [ObjectIdentifier: Probe] = [:]

        @MainActor
        static func closeLeftovers() async {
            for probe in open.values { try? await probe.close() }
        }

        /// Whether the probe printed `line` as a line of its own.
        @MainActor
        func printed(_ line: String) -> Bool {
            surface.allText.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == line }
        }

        @MainActor
        func waitFor(_ line: String, timeout: Duration = .seconds(30)) async throws {
            try await GhosttyTestHost.shared.waitUntil("\(path): \(line)", timeout: timeout, screen: { self.surface.allText }) {
                self.printed(line)
            }
        }

        /// The bytes the probe reported under `tag`.
        @MainActor
        func bytes(_ tag: String) -> Data {
            let hex = surface.allText.components(separatedBy: "\n")
                .filter { $0.hasPrefix(tag + ":") }
                .map { $0.dropFirst(tag.count + 1).trimmingCharacters(in: .whitespaces) }
                .joined()
            // Anything but whole hex bytes means the report was garbled.
            let digits = Array(hex.utf8)
            guard digits.count % 2 == 0, digits.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                Issue.record("\(path): garbled \(tag) report: \(hex)")
                return Data()
            }
            return Data(stride(from: 0, to: digits.count, by: 2).map {
                UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
            })
        }

        @MainActor
        func value(_ tag: String) -> String? {
            surface.allText.components(separatedBy: "\n").first { $0.hasPrefix(tag + ":") }
                .map { String($0.dropFirst(tag.count + 1)).trimmingCharacters(in: .whitespaces) }
        }

        @MainActor
        func close() async throws {
            Probe.open[ObjectIdentifier(self)] = nil
            link?.close()
            try await surface.free()
        }
    }

    init() async {
        await Probe.closeLeftovers()
    }

    /// Runs the probe on every path at once; returns them once all ended.
    func runEverywhere(_ arguments: [String], timeout: Duration = .seconds(60), width: Double = 800, height: Double = 480,
                       before: (TestSurface) -> Void = { _ in }) async throws -> [Path: Probe] {
        var probes: [Path: Probe] = [:]
        for path in Self.paths {
            probes[path] = try Probe(path, arguments, width: width, height: height, before: before)
        }
        for path in Self.paths { try await probes[path]!.waitFor("END", timeout: timeout) }
        return probes
    }

    /// Runs `record` on every path: the probe writes `setup`, `inject`
    /// drives the terminal once it's listening, and the probe reports
    /// what arrived. Returns each path's bytes.
    func recordEverywhere(setup: String, teardown: String = "", idle: Double = 1.0, hash: Bool = false, quiet: Bool = false,
                          before: (TestSurface) -> Void = { _ in },
                          inject: (TestSurface) async throws -> Void) async throws -> [Path: Probe] {
        var probes: [Path: Probe] = [:]
        var arguments = ["record", Self.hex(setup), Self.hex(teardown), String(idle)]
        if hash { arguments.append("hash") }
        if quiet { arguments.append("quiet") }
        for path in Self.paths {
            let probe = try Probe(path, arguments, before: before)
            probes[path] = probe
            try await probe.waitFor("READY")
            try await inject(probe.surface)
        }
        for path in Self.paths { try await probes[path]!.waitFor("END") }
        return probes
    }

    func closeAll(_ probes: [Path: Probe]) async throws {
        for probe in probes.values { try await probe.close() }
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// `probes` all received the same bytes under `tag`; returns them.
    @discardableResult
    func expectParity(_ probes: [Path: Probe], tag: String = "GOT", _ what: String,
                      sourceLocation: SourceLocation = #_sourceLocation) -> Data {
        let reference = probes[.local]!.bytes(tag)
        for path in Self.remotes {
            let got = probes[path]!.bytes(tag)
            #expect(got == reference, "\(what) over \(path): \(text(got).debugDescription) — locally: \(text(reference).debugDescription)",
                    sourceLocation: sourceLocation)
        }
        return reference
    }

    // MARK: Replies to queries

    static let queries: [(name: String, query: String)] = [
        ("primary device attributes", "\u{1B}[c"),
        ("secondary device attributes", "\u{1B}[>c"),
        ("tertiary device attributes", "\u{1B}[=c"),
        ("terminal name and version (XTVERSION)", "\u{1B}[>q"),
        ("cursor position (DSR 6)", "\u{1B}[5;9H\u{1B}[6n"),
        ("extended cursor position (DECXCPR)", "\u{1B}[5;9H\u{1B}[?6n"),
        ("operating status (DSR 5)", "\u{1B}[5n"),
        ("synchronized output mode (DECRQM 2026)", "\u{1B}[?2026$p"),
        ("bracketed paste mode (DECRQM 2004)", "\u{1B}[?2004$p"),
        ("focus events mode (DECRQM 1004)", "\u{1B}[?1004$p"),
        ("SGR mouse mode (DECRQM 1006)", "\u{1B}[?1006$p"),
        ("grapheme clustering mode (DECRQM 2027)", "\u{1B}[?2027$p"),
        ("color scheme updates mode (DECRQM 2031)", "\u{1B}[?2031$p"),
        ("alternate screen mode (DECRQM 1049)", "\u{1B}[?1049$p"),
        ("kitty keyboard flags", "\u{1B}[?u"),
        ("kitty keyboard flags then DA1 (crossterm's probe)", "\u{1B}[?u\u{1B}[c"),
        ("foreground color (OSC 10)", "\u{1B}]10;?\u{1B}\\"),
        ("background color (OSC 11)", "\u{1B}]11;?\u{07}"),
        ("cursor color (OSC 12)", "\u{1B}]12;?\u{1B}\\"),
        ("palette color (OSC 4)", "\u{1B}]4;1;?\u{1B}\\"),
        ("text area pixel size (XTWINOPS 14)", "\u{1B}[14t"),
        ("cell pixel size (XTWINOPS 16)", "\u{1B}[16t"),
        ("text area cell size (XTWINOPS 18)", "\u{1B}[18t"),
        ("SGR state (DECRQSS)", "\u{1B}P$qm\u{1B}\\"),
        ("cursor style (DECRQSS)", "\u{1B}P$q q\u{1B}\\"),
        ("terminfo name (XTGETTCAP)", "\u{1B}P+q544e\u{1B}\\"),
        ("kitty graphics support", "\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\"),
        ("color scheme (DSR 996)", "\u{1B}[?996n"),
        ("alternate scroll mode (DECRQM 1007)", "\u{1B}[?1007$p"),
        ("in-band resize mode (DECRQM 2048)", "\u{1B}[?2048$p"),
        ("alternate screen mode (DECRQM 1047)", "\u{1B}[?1047$p"),
        ("autowrap mode (DECRQM 7)", "\u{1B}[?7$p"),
        ("cursor visible mode (DECRQM 25)", "\u{1B}[?25$p"),
        ("SGR pixel mouse mode (DECRQM 1016)", "\u{1B}[?1016$p"),
        ("scroll region (DECRQSS)", "\u{1B}[3;10r\u{1B}P$qr\u{1B}\\\u{1B}[r"),
        ("cursor shape, set then read (DECSCUSR, DECRQSS)", "\u{1B}[5 q\u{1B}P$q q\u{1B}\\\u{1B}[0 q"),
        // Co, RGB, Smulx, Setulc, Ms, kbs: what neovim and tmux ask.
        ("terminfo capabilities (XTGETTCAP)", "\u{1B}P+q436f;524742;536d756c78;536574756c63;4d73;6b6273\u{1B}\\"),
        ("palette colors, several (OSC 4)", "\u{1B}]4;0;?;15;?;255;?\u{1B}\\"),
        ("colors (kitty's OSC 21)", "\u{1B}]21;foreground=?;background=?\u{1B}\\"),
        ("kitty keyboard flags, pushed and popped", "\u{1B}[>1u\u{1B}[>3u\u{1B}[?u\u{1B}[<u\u{1B}[?u\u{1B}[<u\u{1B}[?u"),
        ("kitty keyboard flags, per screen", "\u{1B}[?1049h\u{1B}[>1u\u{1B}[?u\u{1B}[?1049l\u{1B}[?u\u{1B}[?1049h\u{1B}[<u\u{1B}[?1049l"),
        ("screen size in cells (XTWINOPS 19)", "\u{1B}[19t"),
    ]

    @Test func repliesToQueriesMatchTheLocalTerminal() async throws {
        let probes = try await runEverywhere(["query"] + Self.queries.map { Self.hex($0.query) }, timeout: .seconds(120))
        var replies: [String: String] = [:]
        for (index, query) in Self.queries.enumerated() {
            replies[query.name] = text(expectParity(probes, tag: "R\(index)", query.name))
        }
        // And they're what the protocols specify.
        let grid = try #require(probes[.local]!.surface.gridSize)
        #expect(replies["primary device attributes"]!.hasPrefix("\u{1B}[?"))
        #expect(replies["terminal name and version (XTVERSION)"]!.hasPrefix("\u{1B}P>|ghostty"))
        #expect(replies["cursor position (DSR 6)"] == "\u{1B}[5;9R")
        #expect(replies["operating status (DSR 5)"] == "\u{1B}[0n")
        #expect(replies["synchronized output mode (DECRQM 2026)"] == "\u{1B}[?2026;2$y")
        #expect(replies["bracketed paste mode (DECRQM 2004)"] == "\u{1B}[?2004;2$y")
        #expect(replies["kitty keyboard flags"] == "\u{1B}[?0u")
        #expect(replies["kitty keyboard flags then DA1 (crossterm's probe)"]!.hasPrefix("\u{1B}[?0u\u{1B}[?"))
        #expect(replies["background color (OSC 11)"]!.hasPrefix("\u{1B}]11;rgb:"))
        #expect(replies["background color (OSC 11)"]!.hasSuffix("\u{07}"))
        #expect(replies["foreground color (OSC 10)"]!.hasPrefix("\u{1B}]10;rgb:"))
        let cell = try #require(probes[.local]!.surface.cellSize)
        #expect(replies["text area pixel size (XTWINOPS 14)"] == "\u{1B}[4;\(grid.rows * cell.height);\(grid.columns * cell.width)t")
        #expect(replies["cell pixel size (XTWINOPS 16)"] == "\u{1B}[6;\(cell.height);\(cell.width)t")
        #expect(replies["text area cell size (XTWINOPS 18)"] == "\u{1B}[8;\(grid.rows);\(grid.columns)t")
        #expect(replies["kitty graphics support"] == "\u{1B}_Gi=31;OK\u{1B}\\")
        #expect(replies["color scheme (DSR 996)"]!.hasPrefix("\u{1B}[?997;"))
        #expect(replies["alternate scroll mode (DECRQM 1007)"] == "\u{1B}[?1007;1$y")
        #expect(replies["in-band resize mode (DECRQM 2048)"] == "\u{1B}[?2048;2$y")
        #expect(replies["alternate screen mode (DECRQM 1047)"] == "\u{1B}[?1047;2$y")
        #expect(replies["autowrap mode (DECRQM 7)"] == "\u{1B}[?7;1$y")
        #expect(replies["cursor visible mode (DECRQM 25)"] == "\u{1B}[?25;1$y")
        #expect(replies["SGR pixel mouse mode (DECRQM 1016)"] == "\u{1B}[?1016;2$y")
        #expect(replies["scroll region (DECRQSS)"] == "\u{1B}P1$r3;10r\u{1B}\\")
        #expect(replies["cursor shape, set then read (DECSCUSR, DECRQSS)"] == "\u{1B}P1$r5 q\u{1B}\\")
        let caps = replies["terminfo capabilities (XTGETTCAP)"]!
        #expect(caps.hasPrefix("\u{1B}P1+r436F=323536\u{1B}\\"), "\(caps.debugDescription)")   // Co=256
        #expect(caps.contains("\u{1B}P1+r524742=38\u{1B}\\"), "\(caps.debugDescription)")       // RGB=8
        #expect(caps.contains("\u{1B}P1+r4D73="), "\(caps.debugDescription)")                     // Ms (OSC 52)
        #expect(replies["palette colors, several (OSC 4)"]!.components(separatedBy: "\u{1B}]4;").count == 4)
        #expect(replies["colors (kitty's OSC 21)"]!.hasPrefix("\u{1B}]21;foreground=rgb:"))
        #expect(replies["kitty keyboard flags, pushed and popped"] == "\u{1B}[?3u\u{1B}[?1u\u{1B}[?0u")
        #expect(replies["kitty keyboard flags, per screen"] == "\u{1B}[?1u\u{1B}[?0u")
        #expect(replies["screen size in cells (XTWINOPS 19)"] == "\u{1B}[9;\(grid.rows);\(grid.columns)t")
        try await closeAll(probes)
    }

    // MARK: Mouse

    @Test func sgrMouseClicksAndWheelAreReported() async throws {
        let probes = try await recordEverywhere(setup: "\u{1B}[?1000h\u{1B}[?1006h", teardown: "\u{1B}[?1000l\u{1B}[?1006l") { surface in
            surface.click(column: 10, row: 5)
            surface.click(column: 20, row: 3, button: GHOSTTY_MOUSE_RIGHT)
            surface.click(column: 2, row: 7, button: GHOSTTY_MOUSE_MIDDLE)
            surface.moveMouse(column: 10, row: 5)
            surface.scroll(dy: 1)
            surface.scroll(dy: -1)
        }
        let got = text(expectParity(probes, "SGR mouse reports"))
        for report in ["\u{1B}[<0;11;6M", "\u{1B}[<0;11;6m", "\u{1B}[<2;21;4M", "\u{1B}[<2;21;4m",
                       "\u{1B}[<1;3;8M", "\u{1B}[<64;11;6M", "\u{1B}[<65;11;6M"] {
            #expect(got.contains(report), "missing \(report.debugDescription) in \(got.debugDescription)")
        }
        try await closeAll(probes)
    }

    @Test func dragsAndMotionAreReportedInTheirModes() async throws {
        // 1002: motion only while a button is held; 1003: all motion.
        let drag = try await recordEverywhere(setup: "\u{1B}[?1002h\u{1B}[?1006h", teardown: "\u{1B}[?1002l\u{1B}[?1006l") { surface in
            surface.moveMouse(column: 4, row: 4)
            surface.moveMouse(column: 5, row: 4)
            surface.mouseButton(GHOSTTY_MOUSE_LEFT, GHOSTTY_MOUSE_PRESS)
            surface.moveMouse(column: 8, row: 4)
            surface.moveMouse(column: 12, row: 6)
            surface.mouseButton(GHOSTTY_MOUSE_LEFT, GHOSTTY_MOUSE_RELEASE)
        }
        let dragged = text(expectParity(drag, "button-event tracking"))
        #expect(dragged.hasPrefix("\u{1B}[<0;6;5M"), "\(dragged.debugDescription)")
        #expect(dragged.contains("\u{1B}[<32;9;5M") && dragged.contains("\u{1B}[<32;13;7M"))
        #expect(dragged.hasSuffix("\u{1B}[<0;13;7m"))
        try await closeAll(drag)

        let motion = try await recordEverywhere(setup: "\u{1B}[?1003h\u{1B}[?1006h", teardown: "\u{1B}[?1003l\u{1B}[?1006l") { surface in
            surface.moveMouse(column: 3, row: 2)
            surface.moveMouse(column: 7, row: 9)
        }
        let moved = text(expectParity(motion, "any-event tracking"))
        #expect(moved.contains("\u{1B}[<35;8;10M"), "\(moved.debugDescription)")
        try await closeAll(motion)
    }

    @Test func legacyMouseEncodingIsReported() async throws {
        // X10-style bytes (no 1006): ESC [ M, then 32 + button, column, row.
        let probes = try await recordEverywhere(setup: "\u{1B}[?1000h", teardown: "\u{1B}[?1000l") { surface in
            surface.click(column: 10, row: 5)
        }
        let got = expectParity(probes, "legacy mouse reports")
        let press: [UInt8] = [0x1B, 0x5B, 0x4D, 32, 43, 38]   // button 0 at column 11, row 6
        let release: [UInt8] = [0x1B, 0x5B, 0x4D, 35, 43, 38] // 3: released
        #expect(got == Data(press + release), "\(Self.hex(got))")
        try await closeAll(probes)
    }

    @Test func focusChangesAreReported() async throws {
        let probes = try await recordEverywhere(setup: "\u{1B}[?1004h", teardown: "\u{1B}[?1004l") { surface in
            surface.setFocus(false)
            try await GhosttyTestHost.shared.waitUntil("a moment") { true }
            surface.setFocus(true)
        }
        // Turning the mode on reports the current state first.
        #expect(text(expectParity(probes, "focus reports")) == "\u{1B}[I\u{1B}[O\u{1B}[I")
        try await closeAll(probes)
    }

    @Test func theWheelInTheAlternateScreenSendsArrowKeys() async throws {
        // No mouse mode, alternate screen (less, man, git's pager): the
        // terminal turns the wheel into cursor keys.
        let probes = try await recordEverywhere(setup: "\u{1B}[?1049h", teardown: "\u{1B}[?1049l") { surface in
            surface.scroll(dy: 1)
            surface.scroll(dy: -2)
        }
        let got = text(expectParity(probes, "alternate scroll"))
        #expect(got.contains("\u{1B}[A") || got.contains("\u{1B}OA"), "\(got.debugDescription)")
        #expect(got.contains("\u{1B}[B") || got.contains("\u{1B}OB"), "\(got.debugDescription)")
        try await closeAll(probes)
    }

    @Test func theWheelOnTheNormalScreenScrollsBackLocally() async throws {
        // No mouse mode, normal screen: scrolling is the terminal's own
        // (its scrollback); the program hears nothing.
        let lines = (1...300).map { "scrollback line \($0)" }.joined(separator: "\r\n") + "\r\n"
        let probes = try await recordEverywhere(setup: lines, idle: 4, quiet: true) { surface in
            try await surface.waitForScreen("scrollback line 300")
            let bottom = surface.screen
            surface.scroll(dy: 10)
            try await GhosttyTestHost.shared.waitUntil("the viewport to move") { surface.screen != bottom }
            #expect(!surface.screen.contains("scrollback line 300"))
            surface.scroll(dy: -100)
            try await GhosttyTestHost.shared.waitUntil("the viewport to return") { surface.screen.contains("scrollback line 300") }
        }
        #expect(expectParity(probes, "local scrolling").isEmpty)
        try await closeAll(probes)
    }

    // MARK: Keyboard protocols

    func pressKeys(_ surface: TestSurface) {
        surface.press(keycode: Key.escape)
        surface.press(keycode: Key.returnKey, mods: GHOSTTY_MODS_SHIFT)
        surface.press(keycode: Key.returnKey)
        surface.press(keycode: Key.c, mods: GHOSTTY_MODS_CTRL, unshifted: "c")
        surface.press(keycode: Key.a, text: "a", unshifted: "a")
        surface.press(keycode: Key.up, mods: GHOSTTY_MODS_ALT)
    }

    @Test(arguments: [1, 7, 31])
    func kittyKeyboardProtocolKeysAreEncoded(flags: Int) async throws {
        // 1: disambiguate (fish, neovim); 7: + event types and alternate
        // keys (crossterm apps like Codex); 31: everything as escape codes.
        let probes = try await recordEverywhere(setup: "\u{1B}[>\(flags)u", teardown: "\u{1B}[<u") { surface in
            pressKeys(surface)
        }
        let got = text(expectParity(probes, "kitty keyboard flags \(flags)"))
        #expect(got.contains("\u{1B}[27"), "escape: \(got.debugDescription)")
        #expect(got.contains("\u{1B}[13;2"), "shift+enter: \(got.debugDescription)")
        #expect(got.contains("\u{1B}[99;5"), "ctrl+c: \(got.debugDescription)")
        if flags == 1 { #expect(got == "\u{1B}[27u\u{1B}[13;2u\r\u{1B}[99;5ua\u{1B}[1;3A") }
        try await closeAll(probes)
    }

    @Test func modifyOtherKeysEncodesModifiedKeys() async throws {
        let probes = try await recordEverywhere(setup: "\u{1B}[>4;2m", teardown: "\u{1B}[>4;0m") { surface in
            pressKeys(surface)
        }
        let got = text(expectParity(probes, "modifyOtherKeys"))
        #expect(got.contains("\u{1B}[27;2;13~"), "shift+enter: \(got.debugDescription)")
        try await closeAll(probes)
    }

    @Test func legacyKeysAreEncoded() async throws {
        let probes = try await recordEverywhere(setup: "") { surface in
            pressKeys(surface)
        }
        // Shift+Enter is told apart from Enter even here (as xterm's
        // modifyOtherKeys would), so agents can take it as a newline.
        #expect(text(expectParity(probes, "legacy keys")) == "\u{1B}\u{1B}[27;2;13~\r\u{03}a\u{1B}[1;3A")
        try await closeAll(probes)
    }

    // MARK: Pastes and the clipboard

    @Test func aLargeBracketedPasteArrivesWhole() async throws {
        // Far larger than any buffer on the way (64 KiB chunks, the SSH
        // window): a log or file pasted into an editor or an agent's prompt.
        var text = ""
        var line = 0
        while text.utf8.count < 1_000_000 {
            line += 1
            text += "paste line \(line) — ünïcödé ✓ 日本語 \(String(repeating: "x", count: line % 70))\n"
        }
        let pasted = text
        let probes = try await recordEverywhere(setup: "\u{1B}[?2004h", teardown: "\u{1B}[?2004l", idle: 3, hash: true) { surface in
            surface.paste(pasted)
        }
        let reference = probes[.local]!
        // Bracketed, the text goes as is.
        let expected = Data(("\u{1B}[200~" + pasted + "\u{1B}[201~").utf8)
        #expect(reference.value("LEN") == String(expected.count))
        #expect(reference.value("SHA") == SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
        for path in Self.remotes {
            #expect(probes[path]!.value("LEN") == reference.value("LEN"), "\(path)")
            #expect(probes[path]!.value("SHA") == reference.value("SHA"), "\(path)")
        }
        try await closeAll(probes)
    }

    @Test func osc52CopiesToTheClipboard() async throws {
        // What tmux, neovim and agents (Claude Code's /copy) send to copy
        // over SSH.
        let small = "copied over ssh ✓ 日本語"
        let sequence = "\u{1B}]52;c;\(Data(small.utf8).base64EncodedString())\u{1B}\\"
        let probes = try await runEverywhere(["emit", Self.hex(sequence), "0.5"])
        for (path, probe) in probes {
            try await GhosttyTestHost.shared.waitUntil("\(path): the clipboard write") { !probe.surface.clipboardWrites.isEmpty }
            #expect(probe.surface.clipboardWrites == [small], "\(path)")
        }
        try await closeAll(probes)
    }

    @Test func aLargeOSC52CopyArrivesWhole() async throws {
        // 6000 lines: ~200 KiB of base64, several feed chunks and packets.
        let large = (0..<6000).map { "line \($0) of a large copy" }.joined(separator: "\n")
        let probes = try await runEverywhere(["osc52", "6000"])
        for (path, probe) in probes {
            try await GhosttyTestHost.shared.waitUntil("\(path): the clipboard write") { !probe.surface.clipboardWrites.isEmpty }
            #expect(probe.surface.clipboardWrites == [large], "\(path)")
        }
        try await closeAll(probes)
    }

    @Test func osc52ReadsAskAndReplyWithTheClipboard() async throws {
        let clipboard = "on the clipboard ✓ 日本語"
        let query = Self.hex("\u{1B}]52;c;?\u{1B}\\")
        let allowed = try await runEverywhere(["query", query]) { surface in
            surface.clipboardText = clipboard
            surface.allowClipboardRead = true
        }
        let reply = text(expectParity(allowed, tag: "R0", "an allowed clipboard read"))
        #expect(reply == "\u{1B}]52;c;\(Data(clipboard.utf8).base64EncodedString())\u{1B}\\")
        for probe in allowed.values { #expect(probe.surface.clipboardConfirmations == 1) }
        try await closeAll(allowed)

        let denied = try await runEverywhere(["query", query]) { surface in
            surface.clipboardText = clipboard
        }
        let refusal = text(expectParity(denied, tag: "R0", "a denied clipboard read"))
        #expect(!refusal.contains(Data(clipboard.utf8).base64EncodedString()))
        try await closeAll(denied)
    }

    @Test func selectingAndCopyingTakesTheRemoteText() async throws {
        let probes = try await runEverywhere(["emit", Self.hex("\u{1B}[H\u{1B}[2Jcopy me ✓ 日本語\r\nsecond line\r\n"), "1"])
        for (path, probe) in probes {
            let surface = probe.surface
            #expect(surface.perform("select_all"), "\(path)")
            let selected = try #require(surface.selection, "\(path)")
            #expect(selected.contains("copy me ✓ 日本語\nsecond line"), "\(path): \(selected)")
            #expect(surface.perform("copy_to_clipboard"), "\(path)")
            try await GhosttyTestHost.shared.waitUntil("\(path): the copy") { !surface.clipboardWrites.isEmpty }
            #expect(surface.clipboardWrites.last == selected, "\(path)")
        }
        try await closeAll(probes)
    }

    @Test func pastingTheClipboardSendsIt() async throws {
        let clipboard = "pasted from the clipboard ✓"
        let probes = try await recordEverywhere(setup: "\u{1B}[?2004h", teardown: "\u{1B}[?2004l") { surface in
            surface.clipboardText = clipboard
            #expect(surface.perform("paste_from_clipboard"))
        }
        #expect(text(expectParity(probes, "a paste")) == "\u{1B}[200~\(clipboard)\u{1B}[201~")
        try await closeAll(probes)
    }

    // MARK: Images (kitty graphics protocol)

    func isColor(_ pixel: (r: UInt8, g: UInt8, b: UInt8)?, _ r: Int, _ g: Int, _ b: Int) -> Bool {
        guard let pixel else { return false }
        return abs(Int(pixel.r) - r) < 40 && abs(Int(pixel.g) - g) < 40 && abs(Int(pixel.b) - b) < 40
    }

    /// Transmits an image on every path and checks it's acknowledged and
    /// drawn at the top left, `probe` pixels from the image's origin.
    func showImage(width: Int, height: Int, color: (Int, Int, Int), format: Int, chunk: Int, probe point: (Int, Int)) async throws {
        let rgba = String(format: "%02x%02x%02xff", color.0, color.1, color.2)
        let id = Int.random(in: 1000...9999)
        var probes: [Path: Probe] = [:]
        for path in Self.paths {
            probes[path] = try Probe(path, ["image", String(id), String(width), String(height), rgba, String(format), String(chunk)])
        }
        for (path, probe) in probes {
            try await probe.waitFor("END")
            #expect(probe.bytes("R0") == Data("\u{1B}_Gi=\(id);OK\u{1B}\\".utf8),
                    "\(path): \(text(probe.bytes("R0")).debugDescription)")
            let surface = probe.surface
            try await GhosttyTestHost.shared.waitUntil("\(path): the image drawn", timeout: .seconds(15)) {
                isColor(surface.renderedPixel(x: point.0, y: point.1), color.0, color.1, color.2)
            }
            // And nothing beyond it.
            #expect(!isColor(surface.renderedPixel(x: width + 20, y: height / 2), color.0, color.1, color.2), "\(path)")
        }
        try await closeAll(probes)
    }

    @Test func aSmallImageIsShown() async throws {
        try await showImage(width: 48, height: 32, color: (230, 30, 40), format: 32, chunk: 4096, probe: (24, 16))
    }

    @Test func aLargeImageInManyChunksIsShown() async throws {
        // 320×240 RGBA: 300 KiB raw, 400 KiB of base64 in 4 KiB chunks —
        // far past the feed's 64 KiB chunks and the SSH window.
        try await showImage(width: 320, height: 240, color: (30, 200, 60), format: 32, chunk: 4096, probe: (310, 230))
    }

    @Test func aPNGImageIsShown() async throws {
        try await showImage(width: 200, height: 100, color: (40, 60, 230), format: 100, chunk: 1024, probe: (190, 90))
    }

    // MARK: Titles, bells, notifications

    @Test func titlesBellsAndProgressReachTheApp() async throws {
        let sequences = [
            "\u{1B}]2;Relay title ✓\u{07}",
            "\u{07}",
            "\u{1B}]9;4;1;50\u{07}",
            "\u{1B}]7;file://\(ProcessInfo.processInfo.hostName)/tmp/relay\u{07}",
        ].joined()
        let probes = try await runEverywhere(["emit", Self.hex(sequences), "1"])
        let expected = ["title:Relay title ✓", "bell", "progress:1/50"]
        for (path, probe) in probes {
            try await GhosttyTestHost.shared.waitUntil("\(path): the actions", screen: { "\(probe.surface.actions)" }) {
                expected.allSatisfy(probe.surface.actions.contains)
            }
        }
        let reference = Set(probes[.local]!.surface.actions.filter { !$0.hasPrefix("mouse-shape") })
        for path in Self.remotes {
            #expect(Set(probes[path]!.surface.actions.filter { !$0.hasPrefix("mouse-shape") }) == reference, "\(path)")
        }
        try await closeAll(probes)
    }

    @Test func desktopNotificationsReachTheApp() async throws {
        // OSC 9 (iTerm2's, which agents use) and OSC 777 (rxvt's). libghostty
        // allows one notification a second per app, so one path at a time.
        for path in Self.paths {
            let probe = try Probe(path, ["emitseq", "2.5",
                                         Self.hex("\u{1B}]9;Agent needs your attention\u{07}"),
                                         Self.hex("\u{1B}]777;notify;Build;finished\u{1B}\\")])
            try await probe.waitFor("END")
            try await GhosttyTestHost.shared.waitUntil("\(path): the notifications", screen: { "\(probe.surface.actions)" }) {
                probe.surface.actions.filter { $0.hasPrefix("notify:") } == ["notify:|Agent needs your attention", "notify:Build|finished"]
            }
            try await probe.close()
            try await Task.sleep(for: .milliseconds(1200))
        }
    }

    // MARK: Synchronized output

    @Test func aSynchronizedFrameArrivesWhole() async throws {
        // Claude Code and other Ink apps wrap each frame in mode 2026 (that
        // it's supported is the DECRQM 2026 reply above); the frame's
        // content all arrives, across feed chunks and packets.
        let frame = "\u{1B}[?2026h\u{1B}[H\u{1B}[2J" + (1...25).map { "frame row \($0)" }.joined(separator: "\r\n") + "\u{1B}[?2026l"
        let probes = try await runEverywhere(["emit", Self.hex(frame), "1"])
        for (path, probe) in probes {
            #expect(probe.surface.allText.contains("frame row 1\nframe row 2\n"), "\(path)")
            #expect(probe.surface.allText.contains("frame row 25"), "\(path)")
        }
        try await closeAll(probes)
    }
}
}
