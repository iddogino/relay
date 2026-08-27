import Foundation

/// Runs one-shot, non-interactive management commands through the system
/// OpenSSH client. Scripts are delivered over stdin to a remote `/bin/sh -s`
/// so the remote user's login shell never parses our script text.
///
/// Child processes are spawned with `posix_spawn` and reaped with a
/// `waitpid` poll owned entirely by this code — no NSTask machinery — so a
/// completed child can never leave a caller blocked, and a hard timeout
/// always terminates the child (SIGTERM, then SIGKILL).
public struct SSHCommandRunner: Sendable {
    public struct CommandResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public init(exitCode: Int32, stdout: String, stderr: String) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }

        /// Parses `KEY=value` marker lines emitted by management scripts.
        /// First occurrence wins: scripts emit their markers before any data
        /// output (e.g. tmux listings), so later look-alike lines — such as a
        /// hostile tmux session named `RTERM_STATUS=x` — can't override them.
        public func markers() -> [String: String] {
            var result: [String: String] = [:]
            for line in stdout.split(separator: "\n") {
                guard line.hasPrefix("RTERM_") else { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[line.startIndex..<eq])
                if result[key] == nil {
                    result[key] = String(line[line.index(after: eq)...])
                }
            }
            return result
        }
    }

    public enum RunnerError: Error, Sendable {
        case timedOut
        case launchFailed(String)
    }

    public static let sshPath = "/usr/bin/ssh"

    public var connectTimeoutSeconds: Int = 10

    public init() {}

    /// Runs a POSIX script on the remote via `/bin/sh -s` with stdin delivery.
    public func runScript(
        alias: String,
        script: String,
        timeout: Duration = .seconds(30)
    ) async throws -> CommandResult {
        try await Self.runProcess(
            executable: Self.sshPath,
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
                "-T",
                "--",
                alias,
                "/bin/sh -s",
            ],
            stdin: script,
            timeout: timeout
        )
    }

    /// Low-level local process execution with stdin delivery and a hard timeout.
    public static func runProcess(
        executable: String,
        arguments: [String],
        stdin stdinText: String?,
        timeout: Duration
    ) async throws -> CommandResult {
        let spawned = try spawn(executable: executable, arguments: arguments)

        // Feed stdin and pump both output pipes off the cooperative pool.
        // The stop flag bounds draining after the child exits so a grandchild
        // that inherited the pipe write-ends (e.g. a lingering ssh mux master)
        // can never hang a management call.
        let stdinData = stdinText.map { Data($0.utf8) } ?? Data()
        Task.detached(priority: .userInitiated) {
            writeAllAndClose(fd: spawned.stdinFD, data: stdinData)
        }
        let stopDraining = StopFlag()
        async let stdoutData = readUntilEOFOrStopped(fd: spawned.stdoutFD, stop: stopDraining)
        async let stderrData = readUntilEOFOrStopped(fd: spawned.stderrFD, stop: stopDraining)

        let status = await reap(pid: spawned.pid, timeout: timeout)

        // Child is gone; allow a short grace period for the pipes to reach
        // EOF, then stop the readers regardless.
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            stopDraining.raise()
        }

        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrData, encoding: .utf8) ?? ""

        switch status {
        case .timedOut:
            throw RunnerError.timedOut
        case .exited(let code):
            return CommandResult(exitCode: code, stdout: stdout, stderr: stderr)
        }
    }

    // MARK: Spawning

    private struct SpawnedChild {
        let pid: pid_t
        let stdinFD: Int32
        let stdoutFD: Int32
        let stderrFD: Int32
    }

    private static func spawn(executable: String, arguments: [String]) throws -> SpawnedChild {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            [stdinPipe, stdoutPipe, stderrPipe].flatMap { $0 }.filter { $0 >= 0 }.forEach { close($0) }
            throw RunnerError.launchFailed("pipe() failed: errno \(errno)")
        }
        // Parent-side ends never leak into any other child.
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every fd except stdio in the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attributes, argv, environ)

        // Child-side ends belong to the child now.
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard rc == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw RunnerError.launchFailed("posix_spawn(\(executable)) failed: \(String(cString: strerror(rc)))")
        }

        return SpawnedChild(pid: pid, stdinFD: stdinPipe[1], stdoutFD: stdoutPipe[0], stderrFD: stderrPipe[0])
    }

    // MARK: Reaping

    private enum ExitStatus {
        case exited(Int32)
        case timedOut
    }

    /// Polls waitpid until the child exits. On timeout: SIGTERM, brief grace,
    /// SIGKILL — then keeps polling; a killed child always reaps.
    private static func reap(pid: pid_t, timeout: Duration) async -> ExitStatus {
        let deadline = ContinuousClock.now + timeout
        var sentTerm = false
        var sentKill = false
        var timedOut = false

        while true {
            var status: Int32 = 0
            let rc = waitpid(pid, &status, WNOHANG)
            if rc == pid {
                if timedOut { return .timedOut }
                if (status & 0x7F) == 0 {
                    return .exited((status >> 8) & 0xFF)   // WEXITSTATUS
                }
                return .exited(128 + (status & 0x7F))      // terminated by signal
            }
            if rc == -1 {
                // ECHILD shouldn't happen (we're the only reaper); treat as done.
                return timedOut ? .timedOut : .exited(-1)
            }
            if ContinuousClock.now >= deadline {
                timedOut = true
                if !sentTerm {
                    sentTerm = true
                    kill(pid, SIGTERM)
                } else if !sentKill, ContinuousClock.now >= deadline + .milliseconds(500) {
                    sentKill = true
                    kill(pid, SIGKILL)
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Pipe I/O (blocking calls on GCD threads)

    private static func writeAllAndClose(fd: Int32, data: Data) {
        defer { close(fd) }
        // Writing to a pipe whose reader died raises SIGPIPE by default;
        // detect via EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
        var offset = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while offset < buffer.count {
                let n = write(fd, base + offset, buffer.count - offset)
                if n > 0 {
                    offset += n
                } else if n == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    /// Thread-safe latch used to abandon pipe draining after child exit.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func raise() { lock.lock(); value = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func readUntilEOFOrStopped(fd: Int32, stop: StopFlag) async -> Data {
        // Non-blocking reads let the drain loop observe the stop flag.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                loop: while true {
                    let n = read(fd, &buffer, buffer.count)
                    switch n {
                    case 1...:
                        result.append(contentsOf: buffer[0..<n])
                    case 0:
                        break loop // EOF
                    default:
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            if stop.isRaised { break loop }
                            usleep(10_000)
                        } else if errno != EINTR {
                            break loop
                        }
                    }
                }
                close(fd)
                continuation.resume(returning: result)
            }
        }
    }
}
