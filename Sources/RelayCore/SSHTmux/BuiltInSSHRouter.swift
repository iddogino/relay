import Foundation
import os
import RelaySSH

/// Decides, per host, whether a management command goes through the
/// built-in SSH client (`RelaySSH`) or the system `ssh`.
///
/// The built-in client takes a host when Relay's record fully describes
/// it: hostname/port/user plus automatic, key-file or password auth, and
/// nothing inherited from `~/.ssh/config` that it can't honor (ProxyJump,
/// forwards…) or a certificate. Anything else — and any host where it
/// fails before the command starts (unverifiable host key, auth refused)
/// — uses the system ssh, so turning this on never strands a host.
public final class BuiltInSSHRouter: @unchecked Sendable {
    public let pool: SSHConnectionPool
    private let registry: SSHHostRegistry
    private let isEnabled: @Sendable () -> Bool
    private let isTerminalEnabled: @Sendable () -> Bool
    private let passwordLookup: @Sendable (String) -> String?
    private let lock = NSLock()
    private var fallbackUntil: [String: ContinuousClock.Instant] = [:]
    private var passwords: [String: String?] = [:]

    /// How long a host stays on the system ssh after the built-in client
    /// couldn't connect to it.
    private let fallbackCooldown: Duration

    static let logger = Logger(subsystem: "com.iddogino.Relay", category: "ssh")

    public init(
        registry: SSHHostRegistry,
        pool: SSHConnectionPool = .shared,
        isEnabled: @escaping @Sendable () -> Bool,
        isTerminalEnabled: @escaping @Sendable () -> Bool = { false },
        passwordLookup: @escaping @Sendable (String) -> String?,
        fallbackCooldown: Duration = .seconds(600)
    ) {
        self.fallbackCooldown = fallbackCooldown
        self.registry = registry
        self.pool = pool
        self.isEnabled = isEnabled
        self.isTerminalEnabled = isTerminalEnabled
        self.passwordLookup = passwordLookup
    }

    /// The built-in client's target for `alias`'s management commands, or
    /// nil to use the system ssh.
    func target(for alias: String) -> SSHTarget? {
        guard isEnabled() else { return nil }
        return eligibleTarget(for: alias)
    }

    /// The built-in client's target for `alias`'s terminals (a separate
    /// switch, rolled out separately), or nil to use the system ssh.
    func terminalTarget(for alias: String) -> SSHTarget? {
        guard isTerminalEnabled() else { return nil }
        return eligibleTarget(for: alias)
    }

    private func eligibleTarget(for alias: String) -> SSHTarget? {
        guard let host = registry.host(alias: alias) else { return nil }
        let cooling = lock.withLock { () -> Bool in
            guard let until = fallbackUntil[alias] else { return false }
            if ContinuousClock.now < until { return true }
            fallbackUntil[alias] = nil
            return false
        }
        guard !cooling else { return nil }
        return Self.target(for: host, password: { self.password(for: alias) })
    }

    static func target(for host: SSHHost, password: () -> String?) -> SSHTarget? {
        guard host.inheritedOptions.isEmpty, (try? host.validate()) != nil else { return nil }
        let credentials: SSHTarget.Credentials
        switch host.auth {
        case .automatic:
            credentials = .automatic
        case .keyFile(let path, let certificatePath):
            guard certificatePath == nil else { return nil }
            credentials = .keyFile(path: path)
        case .password:
            guard let secret = password(), !secret.isEmpty else { return nil }
            credentials = .password(secret)
        }
        return SSHTarget(
            host: host.hostname,
            port: host.port ?? 22,
            username: host.user ?? NSUserName(),
            credentials: credentials)
    }

    private func password(for alias: String) -> String? {
        if let cached = lock.withLock({ passwords[alias] }) { return cached }
        let value = passwordLookup(alias)
        lock.withLock { passwords[alias] = .some(value) }
        return value
    }

    /// Host settings or saved passwords changed: forget cached passwords
    /// and fallbacks so the next command re-evaluates every host.
    public func hostsChanged() {
        lock.withLock {
            passwords = [:]
            fallbackUntil = [:]
        }
    }

    /// A terminal session couldn't be opened over the built-in client.
    /// Failures that would recur (host key, auth, a refused channel) send
    /// the host to the system ssh for a while; an unreachable host is just
    /// down, and would be for ssh too.
    func noteTerminalOpenFailure(alias: String, error: Error) {
        guard let error = error as? SSHClientError else { return }
        switch error {
        case .hostKeyNotTrusted, .authenticationFailed, .handshakeFailed, .channelFailed:
            noteFallback(alias: alias, error: error)
        case .unreachable, .connectionLost:
            break
        }
    }

    func noteFallback(alias: String, error: SSHClientError) {
        lock.withLock { fallbackUntil[alias] = .now + fallbackCooldown }
        Self.logger.notice("built-in ssh: \(alias, privacy: .public) falls back to system ssh (\(error.description, privacy: .public))")
    }

    /// `SendEnv LANG LC_*` — what the system ssh_config forwards, so remote
    /// commands see the same locale either way.
    static var forwardedEnvironment: [(String, String)] {
        ProcessInfo.processInfo.environment
            .filter { $0.key == "LANG" || $0.key.hasPrefix("LC_") }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}
