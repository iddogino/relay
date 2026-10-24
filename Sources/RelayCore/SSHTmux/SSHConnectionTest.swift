import Foundation

/// "Test Connection" for a host that may not be saved yet: connects with a
/// throwaway config holding just that host, and checks for tmux.
public enum SSHConnectionTest {
    public enum Outcome: Sendable, Equatable {
        /// Connected; tmux found (its `-V` line).
        case ok(tmuxVersion: String)
        /// Connected, but tmux isn't installed (or isn't findable).
        case noTmux
        /// The host's key isn't in known_hosts yet. Retry with
        /// `trustNewHostKey` once the user agrees.
        case unknownHostKey(String)
        /// The host's key changed — never accepted automatically.
        case changedHostKey(String)
        case authenticationFailed(String)
        case unreachable(String)
        /// Password hosts need Relay's own SSH client (management commands
        /// can't answer a password prompt through the system ssh).
        case passwordNotSupportedYet
    }

    public static func run(
        host: SSHHost,
        trustNewHostKey: Bool = false,
        userConfigPath: String = SSHConfigDiscovery.defaultConfigPath
    ) async -> Outcome {
        if case .password = host.auth { return .passwordNotSupportedYet }
        do { try host.validate() } catch { return .unreachable(error.localizedDescription) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-hosttest-\(UUID().uuidString)")
        let config = directory.appendingPathComponent("ssh_config")
        SSHHostRegistry.writePrivately(
            SSHHostRegistry.render(hosts: [host], userConfigPath: userConfigPath, systemConfigPath: "/etc/ssh/ssh_config"),
            to: config)
        defer { try? FileManager.default.removeItem(at: directory) }

        var arguments = ["-F", config.path, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        if trustNewHostKey { arguments += ["-o", "StrictHostKeyChecking=accept-new"] }
        arguments += ["-T", "--", host.alias, "/bin/sh -s"]
        let script = """
        set -u
        \(SSHTmuxScripts.resolveTmuxFragment)
        printf 'RTERM_STATUS=ok\\n'
        printf 'RTERM_TMUX_VERSION=%s\\n' "$("$tmux_path" -V 2>/dev/null || printf 'tmux')"
        """
        let result: SSHCommandRunner.CommandResult
        do {
            result = try await SSHCommandRunner.runProcess(
                executable: SSHCommandRunner.sshPath, arguments: arguments, stdin: script, timeout: .seconds(20))
        } catch {
            return .unreachable("The connection timed out.")
        }
        return outcome(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    /// Classifies a test run. Pure; unit-tested.
    static func outcome(exitCode: Int32, stdout: String, stderr: String) -> Outcome {
        let markers = SSHCommandRunner.CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr).markers()
        if exitCode == 0, markers["RTERM_STATUS"] == "ok" {
            return .ok(tmuxVersion: markers["RTERM_TMUX_VERSION"] ?? "tmux")
        }
        if exitCode == 21 || markers["RTERM_STATUS"] == "no_tmux" { return .noTmux }
        let detail = SSHTmuxRuntimeProvider.sanitizedStderr(stderr)
        let lowered = stderr.lowercased()
        if lowered.contains("remote host identification has changed") || (lowered.contains("host key for") && lowered.contains("has changed")) {
            return .changedHostKey(detail)
        }
        if lowered.contains("host key verification failed") || (lowered.contains("no ") && lowered.contains("host key is known")) {
            return .unknownHostKey(detail)
        }
        if lowered.contains("permission denied") || lowered.contains("no supported authentication")
            || lowered.contains("too many authentication failures") {
            return .authenticationFailed(detail)
        }
        return .unreachable(detail.isEmpty ? "ssh exited with status \(exitCode)." : detail)
    }
}
