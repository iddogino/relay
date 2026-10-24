import Darwin
import Foundation
import RelaySSH

/// A real OpenSSH server for tests: the system `sshd`, run as the current
/// user on a free loopback port with throwaway host and client keys. It
/// authenticates only the generated client key and logs in as the current
/// user (a non-root sshd can't switch users), so sessions run the user's
/// real shell environment on real ptys — exactly the remote end Relay's
/// client talks to in production.
public final class TestSSHD: @unchecked Sendable {
    public let port: Int
    public let directory: URL
    public let clientKeyPath: String
    public let knownHostsPath: String
    public let logPath: String
    private let process: Process

    public enum StartError: Error, CustomStringConvertible {
        case unavailable(String)
        case didNotStart(String)

        public var description: String {
            switch self {
            case .unavailable(let detail): return "sshd unavailable: \(detail)"
            case .didNotStart(let log): return "sshd did not start:\n\(log)"
            }
        }
    }

    public static let sshdPath = "/usr/sbin/sshd"

    /// Starts sshd; throws if it can't (e.g. no sshd on this system).
    public init(acceptEnv: [String] = ["LANG", "LC_*", "RELAY_*"]) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.sshdPath) else {
            throw StartError.unavailable("\(Self.sshdPath) not found")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        let hostKey = dir.appendingPathComponent("host_ed25519").path
        clientKeyPath = dir.appendingPathComponent("client_ed25519").path
        try Self.keygen(hostKey)
        try Self.keygen(clientKeyPath)
        let authorizedKeys = dir.appendingPathComponent("authorized_keys").path
        try FileManager.default.copyItem(atPath: clientKeyPath + ".pub", toPath: authorizedKeys)
        chmod(authorizedKeys, 0o600)
        logPath = dir.appendingPathComponent("sshd.log").path
        knownHostsPath = dir.appendingPathComponent("known_hosts").path

        var lastLog = ""
        for _ in 0..<5 {
            let port = try Self.freePort()
            let config = dir.appendingPathComponent("sshd_config")
            try """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKey)
            AuthorizedKeysFile \(authorizedKeys)
            AuthenticationMethods publickey
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            UsePAM no
            StrictModes no
            PidFile none
            AcceptEnv \(acceptEnv.joined(separator: " "))
            LogLevel VERBOSE
            """.write(to: config, atomically: true, encoding: .utf8)

            FileManager.default.createFile(atPath: logPath, contents: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.sshdPath)
            process.arguments = ["-D", "-e", "-f", config.path]
            let log = FileHandle(forWritingAtPath: logPath)
            process.standardError = log
            process.standardOutput = log
            try process.run()
            try? log?.close()

            if Self.waitForListener(port: port, process: process) {
                Self.bindLifetime(of: process.processIdentifier, directory: dir)
                self.port = port
                self.process = process
                let hostPub = try String(contentsOfFile: hostKey + ".pub", encoding: .utf8)
                    .split(separator: " ").prefix(2).joined(separator: " ")
                try "[127.0.0.1]:\(port) \(hostPub)\n".write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
                return
            }
            process.terminate()
            process.waitUntilExit()
            lastLog = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        }
        throw StartError.didNotStart(lastLog)
    }

    /// A client target authenticating with the generated key.
    public var target: SSHTarget {
        SSHTarget(host: "127.0.0.1", port: port, username: NSUserName(), credentials: .keyFile(path: clientKeyPath))
    }

    public var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

    public func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Ensures sshd never outlives the test process, which the suites'
    /// shared (static, never deinitialized) servers otherwise would: killed
    /// at normal exit, and by a watchdog if the test process dies.
    private static func bindLifetime(of pid: pid_t, directory: URL) {
        startedLock.withLock {
            startedPIDs.append(pid)
            if !exitHookInstalled {
                exitHookInstalled = true
                atexit {
                    for pid in TestSSHD.startedLock.withLock({ TestSSHD.startedPIDs }) { kill(pid, SIGTERM) }
                }
            }
        }
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 1; done; kill \(pid) 2>/dev/null; rm -rf '\(directory.path)'"]
        watchdog.standardInput = FileHandle.nullDevice
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try? watchdog.run()
    }

    private static let startedLock = NSLock()
    nonisolated(unsafe) private static var startedPIDs: [pid_t] = []
    nonisolated(unsafe) private static var exitHookInstalled = false

    private static func keygen(_ path: String) throws {
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "relay-test", "-f", path]
        try keygen.run()
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else { throw StartError.unavailable("ssh-keygen failed") }
    }

    /// A port the kernel just handed out (and released); sshd binds it next.
    public static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.unavailable("socket: \(errno)") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { throw StartError.unavailable("bind: \(errno)") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func waitForListener(port: Int, process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard process.isRunning else { return false }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(fd)
            if connected { return true }
            usleep(50_000)
        }
        return false
    }
}
