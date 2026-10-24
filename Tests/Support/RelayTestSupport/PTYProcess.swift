import Darwin
import Foundation
import RelayPTYSpawn

/// A real process on a real pty: the test stand-in for whatever a server
/// runs for an SSH session.
public final class PTYProcess: @unchecked Sendable {
    public let pid: pid_t
    /// The pty master; owned by whoever adopts it (see `takeMaster`).
    public private(set) var master: Int32

    private init(pid: pid_t, master: Int32) {
        self.pid = pid
        self.master = master
    }

    public enum SpawnError: Error {
        case openpty(Int32)
        case spawn(Int32)
    }

    /// Starts `argv` on a new pty of the given size.
    public static func spawn(
        _ argv: [String],
        environment: [String: String],
        columns: Int,
        rows: Int,
        widthPx: Int = 0,
        heightPx: Int = 0,
        cwd: String? = nil
    ) throws -> PTYProcess {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
            ws_xpixel: UInt16(clamping: widthPx), ws_ypixel: UInt16(clamping: heightPx))
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw SpawnError.openpty(errno) }
        defer { close(slave) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        let path = argv[0]
        let env = environment.map { "\($0.key)=\($0.value)" }
        let pid = withCStrings(argv) { cArgv in
            withCStrings(env) { cEnv in
                if let cwd {
                    return cwd.withCString { relay_spawn_on_pty(path, cArgv, cEnv, slave, $0) }
                }
                return relay_spawn_on_pty(path, cArgv, cEnv, slave, nil)
            }
        }
        guard pid > 0 else {
            let err = errno
            close(master)
            throw SpawnError.spawn(err)
        }
        return PTYProcess(pid: pid, master: master)
    }

    /// Hands the master descriptor to a new owner (which closes it).
    public func takeMaster() -> Int32 {
        let fd = master
        master = -1
        return fd
    }

    public static func resize(master: Int32, columns: Int, rows: Int, widthPx: Int, heightPx: Int) {
        var size = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
            ws_xpixel: UInt16(clamping: widthPx), ws_ypixel: UInt16(clamping: heightPx))
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// How a waited-for process ended.
    public enum Termination: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
    }

    /// Calls `handler` (on a background thread) when the process ends.
    /// Call at most once: it reaps the process.
    public func onExit(_ handler: @escaping @Sendable (Termination) -> Void) {
        let pid = pid
        // A blocking waitpid can't miss an exit that happened first, as a
        // kqueue source on an already-exited process can.
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 {
                guard errno == EINTR else { return }
            }
            let low = status & 0x7f
            handler(low == 0 ? .exited((status >> 8) & 0xff) : .signaled(low))
        }
        thread.name = "pty-wait-\(pid)"
        thread.start()
    }

    deinit {
        if master >= 0 { close(master) }
    }
}

func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
