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
        cwd: String? = nil,
        modes: (inout termios) -> Void = { _ in }
    ) throws -> PTYProcess {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
            ws_xpixel: UInt16(clamping: widthPx), ws_ypixel: UInt16(clamping: heightPx))
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw SpawnError.openpty(errno) }
        defer { close(slave) }
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0 {
            modes(&attributes)
            tcsetattr(slave, TCSANOW, &attributes)
        }
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

    /// Starts `argv` with pipes for stdin, stdout and stderr (what sshd
    /// does for a command without a pty), in a process group of its own.
    /// The returned descriptors are the parent's ends: write `stdin`, read
    /// `stdout`/`stderr`; the caller owns them.
    public static func spawnPiped(
        _ argv: [String],
        environment: [String: String]
    ) throws -> (process: PTYProcess, stdin: Int32, stdout: Int32, stderr: Int32) {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1], error: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&error) == 0 else { throw SpawnError.spawn(errno) }
        for fd in [input[1], output[0], error[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, error[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default signal handling, nothing blocked (as sshd starts
        // programs), so a hangup ends it.
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var pid: pid_t = 0
        let env = environment.map { "\($0.key)=\($0.value)" }
        let rc = withCStrings(argv) { cArgv in
            withCStrings(env) { cEnv in
                posix_spawn(&pid, argv[0], &actions, &attributes, UnsafeMutablePointer(mutating: cArgv), UnsafeMutablePointer(mutating: cEnv))
            }
        }
        for fd in [input[0], output[1], error[1]] { close(fd) }
        guard rc == 0 else {
            for fd in [input[1], output[0], error[0]] { close(fd) }
            throw SpawnError.spawn(rc)
        }
        return (PTYProcess(pid: pid, master: -1), input[1], output[0], error[0])
    }

    /// Hands the master descriptor to a new owner (which closes it).
    public func takeMaster() -> Int32 {
        let fd = master
        master = -1
        return fd
    }

    /// Applies SSH terminal modes (RFC 4254 opcodes, as a pty request
    /// carries them) to `attributes`, as sshd does; unknown ones are skipped.
    public static func apply(sshModes: [UInt8: UInt32], to attributes: inout termios) {
        let characters: [UInt8: Int32] = [
            1: VINTR, 2: VQUIT, 3: VERASE, 4: VKILL, 5: VEOF, 6: VEOL, 7: VEOL2, 8: VSTART, 9: VSTOP,
            10: VSUSP, 11: VDSUSP, 12: VREPRINT, 13: VWERASE, 14: VLNEXT, 17: VSTATUS, 18: VDISCARD,
        ]
        let input: [UInt8: tcflag_t] = [30: tcflag_t(IGNPAR), 31: tcflag_t(PARMRK), 32: tcflag_t(INPCK), 33: tcflag_t(ISTRIP), 34: tcflag_t(INLCR), 35: tcflag_t(IGNCR), 36: tcflag_t(ICRNL),
                                     38: tcflag_t(IXON), 39: tcflag_t(IXANY), 40: tcflag_t(IXOFF), 41: tcflag_t(IMAXBEL), 42: tcflag_t(IUTF8)]
        let local: [UInt8: tcflag_t] = [50: tcflag_t(ISIG), 51: tcflag_t(ICANON), 53: tcflag_t(ECHO), 54: tcflag_t(ECHOE), 55: tcflag_t(ECHOK), 56: tcflag_t(ECHONL), 57: tcflag_t(NOFLSH),
                                     58: tcflag_t(TOSTOP), 59: tcflag_t(IEXTEN), 60: tcflag_t(ECHOCTL), 61: tcflag_t(ECHOKE), 62: tcflag_t(PENDIN)]
        let output: [UInt8: tcflag_t] = [70: tcflag_t(OPOST), 72: tcflag_t(ONLCR), 73: tcflag_t(OCRNL), 74: tcflag_t(ONOCR), 75: tcflag_t(ONLRET)]
        func set(_ flags: inout tcflag_t, _ bit: tcflag_t, _ on: Bool) {
            if on { flags |= bit } else { flags &= ~bit }
        }
        for (opcode, value) in sshModes {
            if let index = characters[opcode] {
                withUnsafeMutableBytes(of: &attributes.c_cc) { $0[Int(index)] = UInt8(truncatingIfNeeded: value) }
            } else if let bit = input[opcode] {
                set(&attributes.c_iflag, bit, value != 0)
            } else if let bit = local[opcode] {
                set(&attributes.c_lflag, bit, value != 0)
            } else if let bit = output[opcode] {
                set(&attributes.c_oflag, bit, value != 0)
            } else if opcode == 128 {
                cfsetispeed(&attributes, speed_t(value))
            } else if opcode == 129 {
                cfsetospeed(&attributes, speed_t(value))
            }
        }
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
