import AppKit
import Darwin
import Foundation
import GhosttyKit
import Testing
@testable import RelayGhosttyIO
import RelaySSH

/// The patched libghostty's manual I/O mode, through its C API: real
/// surfaces whose program output is fed in and whose writes, sizes, and
/// exits come out through the callbacks.
/// libghostty's state is process-wide, and the end-to-end suite's fake
/// server runs its programs as this process's children, which the process
/// checks here would see: the Ghostty suites run one at a time.
@Suite("Ghostty I/O", .serialized)
struct GhosttyIOSuites {}

/// macOS virtual keycodes used by the tests.
enum Key {
    static let a: UInt32 = 0
    static let c: UInt32 = 8
    static let returnKey: UInt32 = 36
    static let escape: UInt32 = 53
    static let up: UInt32 = 126
}

extension GhosttyIOSuites {
@Suite("Ghostty manual I/O (C API)", .serialized)
@MainActor
struct ManualIOSurfaceTests {

    func manualSurface(width: Double = 800, height: Double = 480, waitAfterCommand: Bool = false) throws -> TestSurface {
        let surface = TestSurface(mode: .manual(ManualTerminalIO()), width: width, height: height, waitAfterCommand: waitAfterCommand)
        try #require(surface.surface != nil, "ghostty_surface_new failed")
        return surface
    }

    // MARK: Creation

    @Test func aManualSurfaceRunsNoProcessAndReportsItsSize() async throws {
        let before = Self.childPIDs()
        let surface = try manualSurface()
        try await GhosttyTestHost.shared.waitUntil("a size report") { surface.sizes.last == surface.gridSize }
        let size = try #require(surface.gridSize)
        #expect(size.columns > 20 && size.rows > 5)
        #expect(surface.io?.size == size)
        // No login wrapper, no shell: nothing an exec surface starts. (Other
        // suites may start unrelated helpers meanwhile.)
        // An exec surface's child is the setuid login(1), whose name this
        // process can't read; children other suites start meanwhile (their
        // servers' programs) have readable names.
        let spawned = Self.childPIDs().subtracting(before).map(Self.processName)
        #expect(!spawned.contains { $0.isEmpty || $0 == "login" }, "\(spawned)")
        // And libghostty knows of no process for it.
        #expect(ghostty_surface_foreground_pid(try #require(surface.surface)) == 0)
        try await surface.free()
    }

    @Test func invalidManualConfigurationsAreRejected() async throws {
        let missingWrite = TestSurface(mode: .raw { config in
            config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        })
        #expect(missingWrite.surface == nil)

        let unknownMode = TestSurface(mode: .raw { config in
            config.io_mode = ghostty_surface_io_mode_e(rawValue: 7)
        })
        #expect(unknownMode.surface == nil)

        // A manual surface has no command to run.
        let withCommand = TestSurface(mode: .raw { config in
            config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
            config.io_write_cb = { _, _, _ in }
            config.command = UnsafePointer(strdup("/bin/echo hi"))
        })
        #expect(withCommand.surface == nil)
    }

    @Test func aFailedAttachReleasesTheIOObject() async throws {
        weak var weakIO: ManualTerminalIO?
        do {
            let io = ManualTerminalIO()
            weakIO = io
            var config = ghostty_surface_config_new()
            io.configure(&config)
            io.attach(nil)
        }
        #expect(weakIO == nil)
    }

    // MARK: Output

    @Test func fedOutputIsRendered() async throws {
        let surface = try manualSurface()
        surface.feed("hello \u{1B}[1;31mworld\u{1B}[0m\r\nsecond line")
        try await surface.waitForScreen("hello world")
        #expect(surface.screenLines.first == "hello world")
        #expect(surface.screenLines.dropFirst().first == "second line")
        try await surface.free()
    }

    @Test func utf8SplitAcrossFeedsIsReassembled() async throws {
        let surface = try manualSurface()
        let text = "✓ done — 日本語 🚀 é"
        for byte in Array(text.utf8) { surface.feed(Data([byte])) }
        try await surface.waitForScreen(text)
        try await surface.free()
    }

    @Test func escapeSequencesSplitAcrossFeedsStillParse() async throws {
        let surface = try manualSurface()
        // Clear, move to row 5 column 10, print X — one byte at a time.
        for byte in Array("\u{1B}[2J\u{1B}[5;10HX".utf8) { surface.feed(Data([byte])) }
        try await surface.waitForScreen("X")
        let lines = surface.screenLines
        #expect(lines.count >= 5)
        #expect(lines[4] == String(repeating: " ", count: 9) + "X")
        try await surface.free()
    }

    @Test func alternateScreenRoundTrips() async throws {
        let surface = try manualSurface()
        surface.feed("primary text")
        try await surface.waitForScreen("primary text")
        surface.feed("\u{1B}[?1049h\u{1B}[Hfull-screen app")
        try await surface.waitForScreen("full-screen app")
        #expect(!surface.screen.contains("primary text"))
        surface.feed("\u{1B}[?1049l")
        try await GhosttyTestHost.shared.waitUntil("primary screen back") {
            surface.screen.contains("primary text") && !surface.screen.contains("full-screen app")
        }
        try await surface.free()
    }

    // MARK: Input

    @Test func typedTextAndKeysReachTheWriteCallback() async throws {
        let surface = try manualSurface()
        surface.type("ls -la")
        try await surface.waitForWritten("typed text") { $0 == Data("ls -la".utf8) }
        surface.written.clear()

        surface.press(keycode: Key.returnKey)
        try await surface.waitForWritten("return") { $0 == Data("\r".utf8) }
        surface.written.clear()

        surface.press(keycode: Key.c, mods: GHOSTTY_MODS_CTRL, unshifted: "c")
        try await surface.waitForWritten("ctrl-c") { $0 == Data([0x03]) }
        surface.written.clear()

        surface.press(keycode: Key.a, text: "a", unshifted: "a")
        try await surface.waitForWritten("a key") { $0 == Data("a".utf8) }
        surface.written.clear()

        surface.press(keycode: Key.escape)
        try await surface.waitForWritten("escape") { $0 == Data([0x1B]) }
        try await surface.free()
    }

    @Test func keyEncodingFollowsModesTheProgramSets() async throws {
        let surface = try manualSurface()
        surface.press(keycode: Key.up)
        try await surface.waitForWritten("normal cursor key") { $0 == Data("\u{1B}[A".utf8) }
        surface.written.clear()

        // DECCKM: application cursor keys (what vim and less turn on).
        try await surface.feedAndWait("\u{1B}[?1h")
        surface.press(keycode: Key.up)
        try await surface.waitForWritten("application cursor key") { $0 == Data("\u{1B}OA".utf8) }

        surface.written.clear()
        try await surface.feedAndWait("\u{1B}[?1l")
        surface.press(keycode: Key.up)
        try await surface.waitForWritten("normal cursor key again") { $0 == Data("\u{1B}[A".utf8) }
        try await surface.free()
    }

    @Test func repliesToTerminalQueriesGoToTheProgram() async throws {
        let surface = try manualSurface()
        // Cursor position report (DSR 6) after moving to row 3, column 7.
        surface.feed("\u{1B}[3;7H\u{1B}[6n")
        try await surface.waitForWritten("a cursor position report") { $0 == Data("\u{1B}[3;7R".utf8) }
        surface.written.clear()

        // Primary device attributes.
        surface.feed("\u{1B}[c")
        try await surface.waitForWritten("device attributes") {
            let text = String(decoding: $0, as: UTF8.self)
            return text.hasPrefix("\u{1B}[?") && text.hasSuffix("c")
        }
        surface.written.clear()

        // Background color query (OSC 11), as vim and others send.
        surface.feed("\u{1B}]11;?\u{07}")
        try await surface.waitForWritten("a color report") {
            String(decoding: $0, as: UTF8.self).hasPrefix("\u{1B}]11;rgb:")
        }
        try await surface.free()
    }

    @Test func linefeedModeSendsCRLF() async throws {
        let surface = try manualSurface()
        try await surface.feedAndWait("\u{1B}[20h")
        surface.press(keycode: Key.returnKey)
        try await surface.waitForWritten("CRLF") { $0 == Data("\r\n".utf8) }
        try await surface.free()
    }

    @Test func pastesAreBracketedWhenTheProgramAsks() async throws {
        let surface = try manualSurface()
        try await surface.feedAndWait("\u{1B}[?2004h")
        surface.paste("first line\nsecond line")
        try await surface.waitForWritten("a bracketed paste") {
            let text = String(decoding: $0, as: UTF8.self)
            return text.hasPrefix("\u{1B}[200~") && text.hasSuffix("\u{1B}[201~")
        }
        let text = String(decoding: surface.written.data, as: UTF8.self)
        #expect(text.contains("first line"))
        #expect(text.contains("second line"))
        try await surface.free()
    }

    @Test func inputBeforeAHandlerIsKeptAndDeliveredInOrder() async throws {
        let io = ManualTerminalIO()
        let surface = TestSurface(mode: .manual(io), captureIO: false)
        try #require(surface.surface != nil)
        surface.type("early ")
        surface.type("keys")
        try await GhosttyTestHost.shared.waitUntil("input to be buffered") {
            io.pendingInputCount == "early keys".utf8.count
        }
        let received = ByteLog()
        io.setInputHandler { received.append($0) }
        surface.type(" later")
        try await GhosttyTestHost.shared.waitUntil("all input") {
            received.data == Data("early keys later".utf8)
        }
        try await surface.free()
    }

    @Test func bufferedInputIsCappedWithoutHoles() async throws {
        let io = ManualTerminalIO()
        let surface = TestSurface(mode: .manual(io), captureIO: false)
        try #require(surface.surface != nil)
        let first = String(repeating: "a", count: ManualTerminalIO.maxPendingInput - 10)
        surface.type(first)
        try await GhosttyTestHost.shared.waitUntil("buffered") { io.pendingInputCount == first.utf8.count }
        // Too big to fit: dropped, and so is everything after it.
        surface.type(String(repeating: "b", count: 100))
        surface.type("c")
        try await Task.sleep(for: .milliseconds(200))
        #expect(io.pendingInputCount == first.utf8.count)
        let received = ByteLog()
        io.setInputHandler { received.append($0) }
        surface.type("d")
        try await GhosttyTestHost.shared.waitUntil("delivery") { received.data.count == first.utf8.count + 1 }
        #expect(received.data == Data((first + "d").utf8))
        try await surface.free()
    }

    // MARK: Size

    @Test func resizingReportsTheNewGridOnce() async throws {
        let surface = try manualSurface(width: 800, height: 480)
        try await GhosttyTestHost.shared.waitUntil("initial size") { surface.sizes.last == surface.gridSize }
        let initial = try #require(surface.gridSize)
        let reportsBefore = surface.sizes.sizes.count

        surface.setSize(width: 1000, height: 600)
        try await GhosttyTestHost.shared.waitUntil("the new size") {
            surface.gridSize != initial && surface.sizes.last == surface.gridSize
        }
        let grown = try #require(surface.gridSize)
        #expect(grown.columns > initial.columns && grown.rows > initial.rows)

        // Same size again: no new report.
        let reportsAfterGrow = surface.sizes.sizes.count
        surface.setSize(width: 1000, height: 600)
        try await Task.sleep(for: .milliseconds(300))
        GhosttyTestHost.shared.tick()
        #expect(surface.sizes.sizes.count == reportsAfterGrow)
        #expect(reportsAfterGrow > reportsBefore)

        // The grid really changed: a full-width line fits on one row.
        surface.feed("\u{1B}[2J\u{1B}[H" + String(repeating: "x", count: grown.columns))
        try await GhosttyTestHost.shared.waitUntil("the line") {
            surface.screenLines.first == String(repeating: "x", count: grown.columns)
        }
        try await surface.free()
    }

    // MARK: Exit

    @Test func anExitClosesTheSurfaceAndStopsWrites() async throws {
        let surface = try manualSurface()
        surface.feed("last words")
        try await surface.waitForScreen("last words")
        surface.io!.reportExit(code: 0)
        try await surface.waitForClose()
        #expect(surface.closedWithProcessAlive == false)

        // The terminal no longer writes to the ended program.
        surface.written.clear()
        surface.type("after exit")
        try await Task.sleep(for: .milliseconds(200))
        #expect(surface.written.data.isEmpty)

        // Only the first exit counts.
        #expect(ghostty_surface_report_exit(surface.surface!, 1) == false)
        try await surface.free()
    }

    @Test func aQuickExitIsNotTreatedAsALaunchFailure() async throws {
        // Exec surfaces show "failed to launch" for very short runs; a
        // manual surface has no launch to fail.
        let surface = try manualSurface()
        surface.io!.reportExit(code: 1)
        try await surface.waitForClose()
        #expect(!surface.allText.contains("failed to launch"))
        try await surface.free()
    }

    @Test func waitAfterCommandKeepsTheEndedTerminalOpen() async throws {
        let surface = try manualSurface(waitAfterCommand: true)
        surface.feed("final output")
        try await surface.waitForScreen("final output")
        surface.io!.reportExit(code: 0)
        try await surface.waitForScreen("Process exited")
        #expect(!surface.closed)
        // Any key then closes it.
        surface.press(keycode: Key.a, text: "a", unshifted: "a")
        try await surface.waitForClose()
        try await surface.free()
    }

    @Test func outputFedBeforeTheExitIsShownFirst() async throws {
        let surface = try manualSurface(waitAfterCommand: true)
        let io = try #require(surface.io)
        for i in 0..<2000 { io.feed(Data("line \(i)\r\n".utf8)) }
        io.reportExit(code: 0)
        try await surface.waitForScreen("Process exited")
        #expect(surface.allText.contains("line 1999"))
        try await surface.free()
    }

    // MARK: Exec mode is unchanged

    @Test func execSurfacesStillRunTheirCommand() async throws {
        let before = Self.childPIDs()
        let surface = TestSurface(mode: .exec(command: "/bin/sh -c 'echo exec-mode-ok; sleep 5'"))
        let raw = try #require(surface.surface)
        // (The process check in the manual test is meaningful: exec mode
        // does start a login process.)
        try await surface.waitForScreen("exec-mode-ok")
        // An exec surface has a process on its pty, and it shows up as the
        // unreadable child the manual test checks for.
        #expect(ghostty_surface_foreground_pid(raw) > 0)
        try await GhosttyTestHost.shared.waitUntil("the login child", timeout: .seconds(3)) {
            Self.childPIDs().subtracting(before).map(Self.processName).contains { $0.isEmpty || $0 == "login" }
        }
        try await surface.waitForScreen("exec-mode-ok")
        // The manual-only API leaves exec surfaces alone.
        let marker = "should-not-appear"
        ghostty_surface_write_output(raw, marker, UInt(marker.utf8.count))
        #expect(ghostty_surface_report_exit(raw, 0) == false)
        try await Task.sleep(for: .milliseconds(200))
        GhosttyTestHost.shared.tick()
        #expect(!surface.allText.contains(marker))
        #expect(!surface.closed)
        try await surface.free()
    }

    // MARK: Teardown and threads

    @Test func aSurfaceWhoseIOThreadFailedToStartStillFrees() async throws {
        // Configured input that opens but can't be read (over libghostty's
        // 10 MiB input limit) fails the IO thread's entry after the backend
        // entered; the thread then drains its loop. A manual surface's exit
        // wait must not keep that loop (and so the free) from finishing.
        let big = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-big-input-\(UUID().uuidString)")
        try Data(count: 11 << 20).write(to: big)
        defer { try? FileManager.default.removeItem(at: big) }
        let app = GhosttyTestHost.shared.makeApp(extraConfig: "input = path:\(big.path)")
        let surface = TestSurface(mode: .manual(ManualTerminalIO()), app: app)
        try #require(surface.surface != nil)
        // libghostty's own report of the failed thread start.
        try await surface.waitForScreen("configured `input`")
        // No exit is reported (that alone would end the wait): the free
        // must finish on the backend's own cleanup.
        try await surface.free()
    }

    @Test func teardownReleasesEverything() async throws {
        weak var weakIO: ManualTerminalIO?
        do {
            let io = ManualTerminalIO()
            weakIO = io
            let surface = TestSurface(mode: .manual(io))
            try #require(surface.surface != nil)
            surface.feed("x")
            try await surface.waitForScreen("x")
            try await surface.free()
        }
        try await GhosttyTestHost.shared.waitUntil("the I/O object to go away") { weakIO == nil }
    }

    @Test func teardownWhileOutputIsStreamingFinishesCleanly() async throws {
        let io = ManualTerminalIO()
        let surface = TestSurface(mode: .manual(io))
        try #require(surface.surface != nil)
        let stop = Flag()
        let enqueued = Counter()
        let completions = Counter()
        let chunk = Data(String(repeating: "streaming output 0123456789 ", count: 200).utf8)
        let feeder = Thread {
            while !stop.isSet {
                enqueued.increment()
                io.feed(chunk) { completions.increment() }
                usleep(100)
            }
        }
        feeder.start()
        try await Task.sleep(for: .milliseconds(300))
        try await surface.free()
        stop.set()
        // Every feed completes — those queued after teardown without
        // touching the surface — so nobody waits on one forever.
        try await GhosttyTestHost.shared.waitUntil("every feed to complete") {
            enqueued.value > 0 && completions.value == enqueued.value
        }
    }

    @Test func teardownDoesNotDeadlockWhenTheAppMailboxIsFull() async throws {
        // Title changes go through the app mailbox; flooding it while the
        // app isn't ticking blocks the feeding queue until the main thread
        // drains it. Teardown must not wait on that queue from main.
        let io = ManualTerminalIO()
        let surface = TestSurface(mode: .manual(io))
        try #require(surface.surface != nil)
        var titles = Data()
        for i in 0..<5000 { titles.append(Data("\u{1B}]0;title \(i)\u{07}".utf8)) }
        for _ in 0..<4 { io.feed(titles) }
        // Don't tick: let the mailbox fill. Then tear down.
        usleep(200_000)
        try await surface.free()
    }

    @Test func heavyOutputWhileResizingStaysConsistent() async throws {
        let io = ManualTerminalIO()
        let surface = TestSurface(mode: .manual(io))
        try #require(surface.surface != nil)
        let done = Flag()
        let feeder = Thread {
            var line = 0
            for _ in 0..<400 {
                var chunk = Data()
                for _ in 0..<100 {
                    chunk.append(Data("\u{1B}[3\(line % 8)mline \(line) \u{1B}[0m colors and text that wraps around the terminal\r\n".utf8))
                    line += 1
                }
                io.feed(chunk)
            }
            io.feed(Data("\u{1B}[0mEND-OF-FLOOD\r\n".utf8)) { done.set() }
        }
        feeder.start()
        var widths = [900.0, 640, 1200, 500, 800]
        while !done.isSet {
            let width = widths.removeFirst()
            widths.append(width)
            surface.setSize(width: width, height: width * 0.6)
            GhosttyTestHost.shared.tick()
            try await Task.sleep(for: .milliseconds(15))
        }
        try await surface.waitForScreen("END-OF-FLOOD", timeout: .seconds(30))
        #expect(surface.allText.contains("line 39999"))
        try await surface.free()
    }

    @Test func manySurfacesStayIndependent() async throws {
        let surfaces = (0..<8).map { _ in TestSurface(mode: .manual(ManualTerminalIO())) }
        for surface in surfaces { try #require(surface.surface != nil) }
        let ios = surfaces.map { $0.io! }
        DispatchQueue.concurrentPerform(iterations: ios.count) { index in
            for line in 0..<200 { ios[index].feed(Data("surface-\(index) line \(line)\r\n".utf8)) }
        }
        for (index, surface) in surfaces.enumerated() {
            try await surface.waitForScreen("surface-\(index) line 199")
            #expect(!surface.allText.contains("surface-\((index + 1) % surfaces.count) "))
        }
        for surface in surfaces { try await surface.free() }
    }

    // MARK: Helpers

    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }

    /// This process's live children, from the kernel's process table.
    static func childPIDs() -> Set<pid_t> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let me = getpid()
        return Set(procs.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_eproc.e_ppid == me && $0.kp_proc.p_stat != SZOMB }
            .map { $0.kp_proc.p_pid })
    }
}

}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
