import Foundation
import RelaySSH

/// Runs one-shot, non-interactive management commands over Relay's built-in
/// SSH client. Scripts are delivered over stdin to a remote `/bin/sh -s` so
/// the remote user's login shell never parses our script text.
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
    }

    /// Starts the stderr of a run that failed because the host needs
    /// setting up in Relay (`RuntimeProviderError.hostNeedsSetup`).
    public static let needsSetupPrefix = "relay-needs-setup: "

    /// Which connection each host's commands use.
    public let builtIn: BuiltInSSHRouter

    public init(builtIn: BuiltInSSHRouter) {
        self.builtIn = builtIn
    }

    /// Runs a POSIX script on the remote via `/bin/sh -s` with stdin
    /// delivery. `onStdout` receives output as it arrives (from an
    /// arbitrary thread). Transport failures come back as exit status 255
    /// with an ssh-style message (which the provider classifies); a host
    /// Relay can't connect to as it's set up, as a "needs setup" one.
    public func runScript(
        alias: String,
        script: String,
        timeout: Duration = .seconds(30),
        onStdout: (@Sendable (Data) -> Void)? = nil
    ) async throws -> CommandResult {
        let target: SSHTarget
        switch builtIn.connection(for: alias) {
        case .needsSetup(let reason):
            return CommandResult(exitCode: 255, stdout: "", stderr: Self.needsSetupPrefix + reason)
        case .ready(let ready):
            target = ready
        }
        do {
            let result = try await builtIn.pool.exec(
                target: target,
                command: "/bin/sh -s",
                stdin: Data(script.utf8),
                environment: BuiltInSSHRouter.forwardedEnvironment,
                timeout: timeout,
                onStdout: onStdout)
            return CommandResult(
                exitCode: result.exitCode,
                stdout: String(data: result.stdout, encoding: .utf8) ?? "",
                stderr: String(data: result.stderr, encoding: .utf8) ?? "")
        } catch SSHConnectionPool.ExecError.timedOut {
            throw RunnerError.timedOut
        } catch let error as SSHClientError {
            if let reason = BuiltInSSHRouter.setupReason(for: error, host: builtIn.host(alias: alias)) {
                return CommandResult(exitCode: 255, stdout: "", stderr: Self.needsSetupPrefix + reason)
            }
            return CommandResult(exitCode: 255, stdout: "", stderr: Self.describe(error, target: target))
        }
    }

    /// An ssh-style message for a transport failure.
    static func describe(_ error: SSHClientError, target: SSHTarget) -> String {
        switch error {
        case .unreachable(let detail):
            return "ssh: connect to host \(target.host) port \(target.port): \(detail)"
        case .connectionLost:
            return "Connection to \(target.host) closed."
        default:
            return "ssh: \(error.description)"
        }
    }
}
