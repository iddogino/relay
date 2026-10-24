import Foundation
import GhosttyKit
import RelaySSH

/// Connects a libghostty surface in manual I/O mode to a program the app
/// runs elsewhere (e.g. over SSH). The program's output goes in through
/// `feed`; what the terminal sends back (keys, pastes, replies to terminal
/// queries) comes out through the input handler, and grid size changes
/// through the resize handler. When the program ends, `reportExit` lets
/// the surface react as it would to a local process exiting.
///
/// Lifecycle: `configure` a surface config, create the surface, `attach`
/// it, and later end with `teardown` — which, not `ghostty_surface_free`,
/// must free the surface.
///
/// Threading: everything here is safe from any thread. Output is fed to
/// the surface in order on a private serial queue, never on the caller's
/// thread: feeding can block (it's how the terminal applies backpressure),
/// and it can wait on the app's main thread, so the main thread must never
/// wait on it. That's why `teardown` is asynchronous.
public final class ManualTerminalIO: @unchecked Sendable {
    public typealias InputHandler = @Sendable (Data) -> Void
    public typealias ResizeHandler = @Sendable (SSHTerminalSize) -> Void

    /// Input kept while no input handler is set (e.g. keys typed while the
    /// connection is still opening). Beyond this, input is dropped.
    public static let maxPendingInput = 64 * 1024

    private let lock = NSLock()
    /// Held while calling a handler, so deliveries keep their order (e.g.
    /// buffered input reaches a new handler before newer input does).
    /// Handlers must not block.
    private let deliveryLock = NSLock()
    private var inputHandler: InputHandler?
    private var resizeHandler: ResizeHandler?
    private var pendingInput = Data()
    /// Input overflowed the buffer: everything until a handler exists is
    /// dropped, so what's kept is a clean prefix rather than having holes.
    private var pendingInputOverflowed = false
    private var latestSize: SSHTerminalSize?
    private var retained: Unmanaged<ManualTerminalIO>?
    /// Set (under `lock`) once teardown starts; no new output is fed.
    private var closing = false

    private let feedQueue = DispatchQueue(label: "com.iddogino.Relay.terminal-feed", qos: .userInteractive)
    /// Only touched on `feedQueue`.
    private var surface: ghostty_surface_t?

    public init() {}

    // MARK: Surface lifecycle

    /// Puts `config` in manual I/O mode, routed to this object. The object
    /// stays alive until `teardown` (or a failed `attach`).
    public func configure(_ config: inout ghostty_surface_config_s) {
        let unmanaged = lock.withLock { () -> Unmanaged<ManualTerminalIO> in
            precondition(retained == nil, "ManualTerminalIO configures one surface")
            let unmanaged = Unmanaged.passRetained(self)
            retained = unmanaged
            return unmanaged
        }
        config.command = nil
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        config.io_write_cb = manualTerminalIOWrite
        config.io_resize_cb = manualTerminalIOResize
        config.io_userdata = unmanaged.toOpaque()
    }

    /// Hands over the surface created from the configured config, or nil
    /// if creation failed (which releases everything).
    public func attach(_ surface: ghostty_surface_t?) {
        guard let surface else {
            lock.withLock {
                closing = true
                inputHandler = nil
                resizeHandler = nil
                retained?.release()
                retained = nil
            }
            return
        }
        let handle = SurfaceHandle(surface)
        feedQueue.async { self.surface = handle.surface }
    }

    /// Stops feeding, then frees the surface with `free` on the main queue
    /// once no output is being fed, then calls `completion` (also on
    /// main). Idempotent: later calls do nothing.
    public func teardown(free: @escaping @Sendable (ghostty_surface_t) -> Void, completion: (@Sendable () -> Void)? = nil) {
        let first = lock.withLock { () -> Bool in
            guard !closing else { return false }
            closing = true
            inputHandler = nil
            resizeHandler = nil
            pendingInput = Data()
            return true
        }
        guard first else { return }
        // Runs after any feed in progress or queued: no feed overlaps the
        // free, and the main thread is never blocked waiting for a feed.
        feedQueue.async {
            let handle = self.surface.map(SurfaceHandle.init)
            self.surface = nil
            DispatchQueue.main.async {
                if let handle { free(handle.surface) }
                // libghostty calls no callback after the free returns.
                self.lock.withLock {
                    self.retained?.release()
                    self.retained = nil
                }
                completion?()
            }
        }
    }

    // MARK: Program → terminal

    /// Feeds the program's output to the terminal, in call order. Calls
    /// `completion` (on an internal queue) once the terminal has processed
    /// it — or dropped it, after teardown.
    public func feed(_ data: Data, completion: (@Sendable () -> Void)? = nil) {
        feedQueue.async {
            defer { completion?() }
            guard let surface = self.surface, !data.isEmpty, !self.isClosing else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_surface_write_output(surface, base, UInt(raw.count))
            }
        }
    }

    /// Reports the program's end, after all output fed before it. The
    /// surface then shows or closes the terminal, as for a local process.
    public func reportExit(code: UInt32) {
        feedQueue.async {
            guard let surface = self.surface, !self.isClosing else { return }
            _ = ghostty_surface_report_exit(surface, code)
        }
    }

    private var isClosing: Bool { lock.withLock { closing } }

    // MARK: Terminal → program

    /// Where the terminal's writes go. Input written while no handler was
    /// set is delivered to the new handler first.
    public func setInputHandler(_ handler: InputHandler?) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        let flushed: Data? = lock.withLock {
            guard !closing else { return nil }
            inputHandler = handler
            guard handler != nil else { return nil }
            pendingInputOverflowed = false
            guard !pendingInput.isEmpty else { return nil }
            let data = pendingInput
            pendingInput = Data()
            return data
        }
        if let flushed, let handler { handler(flushed) }
    }

    /// Where size changes go. A new handler is told the current size.
    public func setResizeHandler(_ handler: ResizeHandler?) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        let size: SSHTerminalSize? = lock.withLock {
            guard !closing else { return nil }
            resizeHandler = handler
            return latestSize
        }
        if let size, let handler { handler(size) }
    }

    /// The terminal's current size, once libghostty has reported it (it
    /// does so while creating the surface).
    public var size: SSHTerminalSize? { lock.withLock { latestSize } }

    /// Input buffered while no handler is set (for tests).
    var pendingInputCount: Int { lock.withLock { pendingInput.count } }

    fileprivate func terminalWrote(_ data: Data) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        let handler: InputHandler? = lock.withLock {
            guard !closing else { return nil }
            if let inputHandler { return inputHandler }
            if !pendingInputOverflowed, pendingInput.count + data.count <= Self.maxPendingInput {
                pendingInput.append(data)
            } else {
                pendingInputOverflowed = true
            }
            return nil
        }
        handler?(data)
    }

    fileprivate func terminalResized(_ size: SSHTerminalSize) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        let handler: ResizeHandler? = lock.withLock {
            guard !closing else { return nil }
            latestSize = size
            return resizeHandler
        }
        handler?(size)
    }
}

/// A surface pointer handed between queues; libghostty's surface API is
/// thread-safe in the ways it's used here.
private struct SurfaceHandle: @unchecked Sendable {
    let surface: ghostty_surface_t
    init(_ surface: ghostty_surface_t) { self.surface = surface }
}

// MARK: - C callbacks
//
// libghostty calls these on its IO thread (and, for the initial size, on
// the thread creating the surface), possibly holding its locks: they copy
// what they need and never call back into libghostty.

private func manualTerminalIOWrite(_ userdata: UnsafeMutableRawPointer?, _ data: UnsafePointer<UInt8>?, _ len: UInt) {
    guard let userdata, let data, len > 0 else { return }
    let io = Unmanaged<ManualTerminalIO>.fromOpaque(userdata).takeUnretainedValue()
    io.terminalWrote(Data(bytes: data, count: Int(len)))
}

private func manualTerminalIOResize(
    _ userdata: UnsafeMutableRawPointer?, _ columns: UInt16, _ rows: UInt16, _ widthPx: UInt32, _ heightPx: UInt32
) {
    guard let userdata else { return }
    let io = Unmanaged<ManualTerminalIO>.fromOpaque(userdata).takeUnretainedValue()
    io.terminalResized(SSHTerminalSize(
        columns: Int(columns), rows: Int(rows), widthPx: Int(widthPx), heightPx: Int(heightPx)))
}
