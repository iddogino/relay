import Foundation
import RelaySSH

/// "Test Connection" for a host that may not be saved yet: connects with a
/// throwaway config holding just that host, and checks for tmux.
/// "Test Connection" for a host that may not be saved yet: signs in with
/// the host's settings as they stand, and checks for tmux.
public enum SSHConnectionTest {
    public enum Outcome: Sendable, Equatable {
        /// Connected; tmux found (its `-V` line).
        case ok(tmuxVersion: String)
        /// Connected, but tmux isn't installed (or isn't findable).
        case noTmux
        /// The host presented a key Relay doesn't know yet: trust it (in
        /// Relay's own known_hosts) once the user agrees, then retry.
        case untrustedHostKey(presentedKey: String)
        /// The same for a jump host on the way (trusted as that host).
        case untrustedJumpHostKey(alias: String, presentedKey: String)
        /// The host's key changed — never accepted automatically.
        case changedHostKey(String)
        case authenticationFailed(String)
        case unreachable(String)
        /// The host signs in with a Relay key this device doesn't have.
        case keyNotOnThisDevice
        /// Relay can't connect with these settings (no password given, a
        /// key file it can't read, a missing jump host…).
        case needsSetup(String)
    }

    /// `hosts` looks up jump hosts (saved Relay hosts) by alias.
    public static func run(
        host: SSHHost,
        password: String?,
        hosts: @Sendable (String) -> SSHHost?,
        pool: SSHConnectionPool,
        keyStore: (any SSHKeyStore)?
    ) async -> Outcome {
        if let id = host.auth.storedKeyID, keyStore?.signingKey(id: id) == nil { return .keyNotOnThisDevice }
        let target: SSHTarget
        switch BuiltInSSHRouter.connection(
            for: host, hosts: hosts, password: { $0 == host.alias ? password : nil },
            hasStoredKey: { keyStore?.signingKey(id: $0) != nil }) {
        case .needsSetup(let reason):
            return .needsSetup(reason)
        case .ready(let ready):
            target = ready
        }
        // Each jump host in turn, so a problem with one is told as that
        // host's (its key can then be trusted from here).
        var hop = host
        var route: [SSHHost] = []
        while let alias = hop.proxyJump, let jump = hosts(alias), !route.contains(where: { $0.alias == alias }) {
            route.insert(jump, at: 0)
            hop = jump
        }
        for (jump, hopTarget) in zip(route, target.jumps) {
            var reach = hopTarget
            reach.jumps = Array(target.jumps.prefix { $0 != hopTarget })
            do {
                try await pool.verifyLogin(target: reach)
            } catch SSHClientError.hostKeyNotTrusted(.unknown, let presented) {
                return .untrustedJumpHostKey(alias: jump.alias, presentedKey: presented)
            } catch SSHClientError.hostKeyNotTrusted {
                return .changedHostKey("Jump host \u{201C}\(jump.alias)\u{201D} now presents a different key.")
            } catch SSHClientError.authenticationFailed {
                return .authenticationFailed("Jump host \u{201C}\(jump.alias)\u{201D} refused the sign-in. \(RelayKeySetup.signInHint(for: jump.auth))")
            } catch {
                break
            }
        }
        do {
            let result = try await pool.exec(
                target: target, command: "/bin/sh -s", stdin: Data(script.utf8), timeout: .seconds(20))
            return outcome(
                exitCode: result.exitCode,
                stdout: String(decoding: result.stdout, as: UTF8.self),
                stderr: String(decoding: result.stderr, as: UTF8.self))
        } catch SSHClientError.hostKeyNotTrusted(.unknown, let presented) {
            return .untrustedHostKey(presentedKey: presented)
        } catch SSHClientError.hostKeyNotTrusted(_, let presented) {
            return .changedHostKey("The host now presents \(KnownHosts.fingerprint(ofPublicKey: presented) ?? "a different key").")
        } catch SSHClientError.authenticationFailed {
            return .authenticationFailed(RelayKeySetup.signInHint(for: host.auth))
        } catch SSHClientError.unreachable(let detail) {
            return .unreachable(detail)
        } catch let error as SSHClientError {
            return .unreachable(error.description)
        } catch {
            return .unreachable("The connection timed out.")
        }
    }

    static let script = """
        set -u
        \(SSHTmuxScripts.resolveTmuxFragment)
        printf 'RTERM_STATUS=ok\\n'
        printf 'RTERM_TMUX_VERSION=%s\\n' "$("$tmux_path" -V 2>/dev/null || printf 'tmux')"
        """

    /// Classifies a test run. Pure; unit-tested.
    static func outcome(exitCode: Int32, stdout: String, stderr: String) -> Outcome {
        let markers = SSHCommandRunner.CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr).markers()
        if exitCode == 0, markers["RTERM_STATUS"] == "ok" {
            return .ok(tmuxVersion: markers["RTERM_TMUX_VERSION"] ?? "tmux")
        }
        if exitCode == 21 || markers["RTERM_STATUS"] == "no_tmux" { return .noTmux }
        let detail = SSHTmuxRuntimeProvider.sanitizedStderr(stderr)
        return .unreachable(detail.isEmpty ? "The test exited with status \(exitCode)." : detail)
    }
}
