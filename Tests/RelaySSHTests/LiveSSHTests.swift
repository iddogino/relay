import Foundation
import Testing
@testable import RelaySSH

/// Runs against a real host when `RELAY_SSH_LIVE_HOST` is set (as
/// `user@host[:port]`, key via ssh-agent / default keys); skipped otherwise.
@Suite("Live SSH")
struct LiveSSHTests {
    static let target: SSHTarget? = {
        guard let spec = ProcessInfo.processInfo.environment["RELAY_SSH_LIVE_HOST"], !spec.isEmpty else { return nil }
        let (user, hostPort) = spec.contains("@")
            ? (String(spec.split(separator: "@")[0]), String(spec.split(separator: "@")[1]))
            : (NSUserName(), spec)
        let parts = hostPort.split(separator: ":")
        return SSHTarget(host: String(parts[0]), port: parts.count > 1 ? Int(parts[1]) ?? 22 : 22,
                         username: user, credentials: .automatic)
    }()

    @Test(.enabled(if: target != nil))
    func runsAScriptOverStdinAndReportsTheExitCode() async throws {
        let pool = SSHConnectionPool()
        let script = "echo hello; echo oops >&2; printf '%s\\n' \"$0\"; exit 3\n"
        let result = try await pool.exec(
            target: Self.target!, command: "/bin/sh -s", stdin: Data(script.utf8), timeout: .seconds(30))
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n/bin/sh\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "oops\n")
    }

    @Test(.enabled(if: target != nil))
    func sharesOneConnectionAcrossConcurrentCommands() async throws {
        let pool = SSHConnectionPool()
        let started = ContinuousClock.now
        let results = try await withThrowingTaskGroup(of: Int32.self) { group in
            for i in 0..<12 {
                group.addTask {
                    try await pool.exec(target: Self.target!, command: "/bin/sh -s",
                                        stdin: Data("exit \(i)\n".utf8), timeout: .seconds(30)).exitCode
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.sorted() == Array(0..<12))
        print("12 commands in \(ContinuousClock.now - started)")
    }

    @Test(.enabled(if: target != nil))
    func streamsStdoutAndHonorsTimeouts() async throws {
        let pool = SSHConnectionPool()
        let chunks = Counter()
        await #expect(throws: SSHConnectionPool.ExecError.self) {
            _ = try await pool.exec(target: Self.target!, command: "/bin/sh -s",
                                    stdin: Data("while :; do echo tick; sleep 1; done\n".utf8),
                                    timeout: .seconds(3), onStdout: { _ in chunks.increment() })
        }
        #expect(chunks.value >= 2)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
