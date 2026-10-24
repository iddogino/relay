import AppKit
import Foundation
import GhosttyKit
import IOSurface
import RelayGhosttyIO
import RelaySSH

/// A headless libghostty app for tests: one process-wide app with a fixed
/// configuration (the user's Ghostty config is never loaded), surfaces on
/// offscreen views, and callbacks recorded for assertions. Everything here
/// runs on the main actor, like an embedding app; `waitUntil` pumps the
/// app loop.
@MainActor
final class GhosttyTestHost {
    static let shared = GhosttyTestHost()

    let app: ghostty_app_t
    private let config: ghostty_config_t

    private init() {
        _ = NSApplication.shared
        precondition(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)
        let config = ghostty_config_new()!
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-ghostty-test-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config")
        try! Self.baseConfig.write(to: file, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: testWakeup,
            action_cb: testAction,
            read_clipboard_cb: testReadClipboard,
            confirm_read_clipboard_cb: testConfirmReadClipboard,
            write_clipboard_cb: testWriteClipboard,
            close_surface_cb: testCloseSurface)
        app = ghostty_app_new(&runtime, config)!
        ghostty_app_set_focus(app, true)
    }

    /// A further app whose configuration adds `extraConfig` (for surfaces
    /// that need different settings). Ticked along with the main one.
    func makeApp(extraConfig: String) -> ghostty_app_t {
        let config = ghostty_config_new()!
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-ghostty-extra-\(UUID().uuidString)")
        try! (Self.baseConfig + "\n" + extraConfig + "\n").write(to: file, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s(
            userdata: nil, supports_selection_clipboard: false,
            wakeup_cb: testWakeup, action_cb: testAction, read_clipboard_cb: testReadClipboard,
            confirm_read_clipboard_cb: testConfirmReadClipboard, write_clipboard_cb: testWriteClipboard,
            close_surface_cb: testCloseSurface)
        let app = ghostty_app_new(&runtime, config)!
        extraApps.append(app)
        return app
    }

    private var extraApps: [ghostty_app_t] = []

    func tick() {
        ghostty_app_tick(app)
        for extra in extraApps { ghostty_app_tick(extra) }
    }

    static let baseConfig = """
    term = xterm-256color
    confirm-close-surface = false
    shell-integration = none
    font-size = 13
    window-padding-x = 0
    window-padding-y = 0
    scrollback-limit = 10000000
    """

    struct Timeout: Error, CustomStringConvertible {
        let what: String
        let screen: String
        var description: String { "timed out waiting for \(what); screen:\n\(screen)" }
    }

    /// Pumps the app loop until `condition` holds.
    func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(10),
        screen: (() -> String)? = nil,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            tick()
            if condition() { return }
            guard ContinuousClock.now < deadline else {
                throw Timeout(what: what, screen: screen?() ?? "")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// One surface on the test host, either in manual I/O mode (through a
/// `ManualTerminalIO`) or running a local command (exec mode).
@MainActor
final class TestSurface {
    let view: NSView
    private(set) var surface: ghostty_surface_t?
    let io: ManualTerminalIO?
    /// Bytes the terminal wrote (manual mode), in order.
    let written = ByteLog()
    let sizes = SizeLog()
    private(set) var closed = false
    private(set) var closedWithProcessAlive: Bool?
    private(set) var clipboardWrites: [String] = []

    var host: GhosttyTestHost { .shared }

    enum Mode {
        case manual(ManualTerminalIO)
        case exec(command: String)
        /// A raw config for negative tests; nil-surface expected.
        case raw((inout ghostty_surface_config_s) -> Void)
    }

    init(mode: Mode, width: Double = 800, height: Double = 480, waitAfterCommand: Bool = false, captureIO: Bool = true,
         app: ghostty_app_t? = nil) {
        let app = app ?? GhosttyTestHost.shared.app
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = 2
        config.font_size = 0
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.wait_after_command = waitAfterCommand

        switch mode {
        case .manual(let manual):
            io = manual
            manual.configure(&config)
            if captureIO {
                let written = written
                let sizes = sizes
                manual.setInputHandler { written.append($0) }
                manual.setResizeHandler { sizes.append($0) }
            }
        case .exec(let command):
            io = nil
            _ = command
        case .raw:
            io = nil
        }
        config.userdata = Unmanaged.passUnretained(self).toOpaque()

        let created: ghostty_surface_t?
        switch mode {
        case .exec(let command):
            created = command.withCString { pointer in
                config.command = pointer
                return ghostty_surface_new(app, &config)
            }
        case .raw(let adjust):
            adjust(&config)
            created = ghostty_surface_new(app, &config)
        case .manual:
            created = ghostty_surface_new(app, &config)
        }
        surface = created
        io?.attach(created)
        if let created {
            TestSurface.live[UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())] = self
            ghostty_surface_set_content_scale(created, 2, 2)
            ghostty_surface_set_size(created, UInt32(width * 2), UInt32(height * 2))
            ghostty_surface_set_focus(created, true)
        }
    }

    /// Surfaces by userdata, for routing callbacks.
    static var live: [UnsafeMutableRawPointer: TestSurface] = [:]

    // MARK: Driving

    func feed(_ text: String) { io!.feed(Data(text.utf8)) }
    func feed(_ data: Data) { io!.feed(data) }

    /// Feeds and waits until the terminal has processed it.
    func feedAndWait(_ text: String) async throws {
        let done = Flag()
        io!.feed(Data(text.utf8)) { done.set() }
        try await host.waitUntil("feed processed") { done.isSet }
    }

    /// Types `text` as key presses, one per character, the way keyboard
    /// input reaches libghostty in the app (`ghostty_surface_key` with the
    /// character's text). Unlike `type`, a program's input modes apply.
    func typeKeys(_ text: String) {
        for character in text {
            let string = String(character)
            press(keycode: Self.keycode(for: character), text: string, unshifted: Character(string.lowercased()))
        }
    }

    /// macOS virtual keycodes for the ANSI layout's letters and digits;
    /// other characters ride on their text alone.
    static func keycode(for character: Character) -> UInt32 {
        let letters: [Character: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
            "n": 45, "m": 46, " ": 49,
        ]
        return letters[Character(character.lowercased())] ?? 0xFFFF
    }

    /// Commits text in one go (`ghostty_surface_text`): libghostty treats
    /// it like a paste, bracketing it when the program enabled that.
    func type(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    /// Presses and releases a key (macOS virtual keycode).
    func press(keycode: UInt32, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE, text: String? = nil, unshifted: Character? = nil) {
        guard let surface else { return }
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var event = ghostty_input_key_s()
            event.action = action
            event.mods = mods
            event.consumed_mods = GHOSTTY_MODS_NONE
            event.keycode = keycode
            event.composing = false
            event.unshifted_codepoint = unshifted.flatMap { $0.unicodeScalars.first?.value } ?? 0
            if let text, action == GHOSTTY_ACTION_PRESS {
                text.withCString { pointer in
                    event.text = pointer
                    _ = ghostty_surface_key(surface, event)
                }
            } else {
                event.text = nil
                _ = ghostty_surface_key(surface, event)
            }
        }
    }

    func paste(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_paste_text(surface, $0, UInt(text.utf8.count)) }
    }

    func setSize(width: Double, height: Double) {
        guard let surface else { return }
        ghostty_surface_set_size(surface, UInt32(width * 2), UInt32(height * 2))
    }

    var gridSize: SSHTerminalSize? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return SSHTerminalSize(columns: Int(size.columns), rows: Int(size.rows),
                               widthPx: Int(size.width_px), heightPx: Int(size.height_px))
    }

    // MARK: Reading

    /// A pixel of the last frame libghostty's Metal renderer presented, as
    /// (red, green, blue). libghostty presents frames as an IOSurface set
    /// as the view's layer contents; this reads it back. Coordinates are in
    /// the surface's pixels (points × scale), origin top-left.
    func renderedPixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let contents = view.layer?.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let row = IOSurfaceGetBaseAddress(surface).advanced(by: y * IOSurfaceGetBytesPerRow(surface))
        let pixel = row.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
        // BGRA.
        return (pixel[2], pixel[1], pixel[0])
    }

    /// The centre of a cell, in surface pixels.
    func cellCenter(column: Int, row: Int) -> (x: Int, y: Int)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        return (column * Int(size.cell_width_px) + Int(size.cell_width_px) / 2,
                row * Int(size.cell_height_px) + Int(size.cell_height_px) / 2)
    }

    func renderedCell(column: Int, row: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let center = cellCenter(column: column, row: row) else { return nil }
        return renderedPixel(x: center.x, y: center.y)
    }

    /// The visible screen's text (trailing blanks trimmed by libghostty).
    var screen: String { read(tag: GHOSTTY_POINT_VIEWPORT) }

    /// Scrollback plus screen.
    var allText: String { read(tag: GHOSTTY_POINT_SCREEN) }

    var screenLines: [String] { screen.components(separatedBy: "\n") }

    private func read(tag: ghostty_point_tag_e) -> String {
        guard let surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    func waitForScreen(_ needle: String, timeout: Duration = .seconds(10)) async throws {
        try await host.waitUntil("\"\(needle)\" on screen", timeout: timeout, screen: { self.allText }) {
            self.allText.contains(needle)
        }
    }

    func waitForWritten(_ what: String, timeout: Duration = .seconds(5), _ condition: @escaping (Data) -> Bool) async throws {
        try await host.waitUntil(what, timeout: timeout, screen: { "written: \(self.written.data.map { String(format: "%02x", $0) }.joined())" }) {
            condition(self.written.data)
        }
    }

    func waitForClose(timeout: Duration = .seconds(10)) async throws {
        try await host.waitUntil("the surface to close", timeout: timeout, screen: { self.allText }) { self.closed }
    }

    // MARK: Teardown

    /// Frees the surface (through the I/O object in manual mode) and waits
    /// for it to finish.
    func free() async throws {
        guard let surface else { return }
        self.surface = nil
        TestSurface.live[UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())] = nil
        if let io {
            let done = Flag()
            io.teardown(free: { ghostty_surface_free($0) }, completion: { done.set() })
            try await host.waitUntil("teardown") { done.isSet }
        } else {
            ghostty_surface_free(surface)
        }
    }

    fileprivate func didClose(processAlive: Bool) {
        closed = true
        closedWithProcessAlive = processAlive
    }

    fileprivate func didWriteClipboard(_ text: String) {
        clipboardWrites.append(text)
    }
}

// MARK: - Thread-safe logs

final class ByteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    private var _chunks = 0
    func append(_ data: Data) { lock.withLock { _data.append(data); _chunks += 1 } }
    var data: Data { lock.withLock { _data } }
    var chunks: Int { lock.withLock { _chunks } }
    func clear() { lock.withLock { _data = Data() } }
}

final class SizeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _sizes: [SSHTerminalSize] = []
    func append(_ size: SSHTerminalSize) { lock.withLock { _sizes.append(size) } }
    var sizes: [SSHTerminalSize] { lock.withLock { _sizes } }
    var last: SSHTerminalSize? { sizes.last }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// MARK: - Runtime callbacks

private func testWakeup(_ userdata: UnsafeMutableRawPointer?) {}

private func testAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    false
}

private func testReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mimesLen: Int,
    _ list: Bool
) -> ghostty_clipboard_read_result_e {
    GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
}

private func testConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata, let state else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard let surface = TestSurface.live[userdata]?.surface else { return }
            ghostty_surface_deny_clipboard_request(surface, state)
        }
    }
}

private func testWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    guard let userdata, let content, len > 0 else { return }
    var text: String?
    for i in 0..<len {
        let item = content[i]
        if let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data {
            text = String(decoding: UnsafeRawBufferPointer(start: data, count: Int(item.len)), as: UTF8.self)
        }
    }
    guard let text else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { TestSurface.live[userdata]?.didWriteClipboard(text) }
    }
}

private func testCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let userdata else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { TestSurface.live[userdata]?.didClose(processAlive: processAlive) }
    }
}
