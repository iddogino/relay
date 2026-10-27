import Foundation
import os
import RelaySSH

/// How Relay connects to each host: its built-in SSH client (`RelaySSH`),
/// with the host's record from Relay's registry — the only way Relay
/// connects anywhere (no system ssh: the App Sandbox and iOS can't run it).
///
/// A host Relay can't connect to as it's set up — its Relay key isn't on
/// this device, no password is saved here, its host key isn't trusted yet,
/// the host refused the sign-in — "needs setup", with a reason the UI shows
/// and the host editor fixes.
public final class BuiltInSSHRouter: @unchecked Sendable {
    public let pool: SSHConnectionPool
    /// Relay's own keys (what `.storedKey` hosts sign in with).
    public let keyStore: (any SSHKeyStore)?
    /// Relay's own known_hosts, where host keys the user trusts in Relay go.
    public let trustedHostsFile: String?
    private let registry: SSHHostRegistry
    private let passwordLookup: @Sendable (String) -> String?
    private let lock = NSLock()
    private var passwords: [String: String?] = [:]

    static let logger = Logger(subsystem: "com.iddogino.Relay", category: "ssh")

    public init(
        registry: SSHHostRegistry,
        pool: SSHConnectionPool = .shared,
        keyStore: (any SSHKeyStore)? = nil,
        trustedHostsFile: String? = nil,
        passwordLookup: @escaping @Sendable (String) -> String?
    ) {
        self.registry = registry
        self.pool = pool
        self.keyStore = keyStore
        self.trustedHostsFile = trustedHostsFile
        self.passwordLookup = passwordLookup
    }

    /// Where a host's commands and terminals go.
    public enum Connection: Sendable, Equatable {
        case ready(SSHTarget)
        /// Relay can't connect as the host is set up; the reason says why.
        case needsSetup(String)
    }

    public func host(alias: String) -> SSHHost? {
        registry.host(alias: alias)
    }

    public func connection(for alias: String) -> Connection {
        guard let host = registry.host(alias: alias) else {
            return .needsSetup("Relay doesn\u{2019}t have a host named \u{201C}\(alias)\u{201D}.")
        }
        return Self.connection(
            for: host, hosts: { self.registry.host(alias: $0) }, password: { self.password(for: $0) },
            hasStoredKey: { self.keyStore?.signingKey(id: $0) != nil })
    }

    /// Why Relay can't connect to `alias` as it's set up, or nil.
    public func setupProblem(for alias: String) -> String? {
        if case .needsSetup(let reason) = connection(for: alias) { return reason }
        return nil
    }

    /// Resolves `host` (and its jump hosts, each a Relay host) into a
    /// target. Pure apart from the lookups; unit-tested.
    static func connection(
        for host: SSHHost,
        hosts: (String) -> SSHHost?,
        password: (String) -> String?,
        hasStoredKey: (String) -> Bool,
        visited: [String] = []
    ) -> Connection {
        // Problems are reported about the host the user picked; a jump
        // host is named.
        let subject = visited.isEmpty ? "This host" : "Its jump host \u{201C}\(host.alias)\u{201D}"
        let possessive = visited.isEmpty ? "this host\u{2019}s" : "\u{201C}\(host.alias)\u{201D}\u{2019}s"
        guard (try? host.validate()) != nil else {
            return .needsSetup("\(subject)\u{2019}s settings are incomplete.")
        }
        if host.inheritedOptions.contains(where: { $0.lowercased().hasPrefix("proxycommand ") }) {
            return .needsSetup("\(subject) connects through a ProxyCommand, which Relay can\u{2019}t run. Use a jump host instead.")
        }
        let credentials: SSHTarget.Credentials
        switch host.auth {
        case .automatic:
            credentials = .automatic
        case .keyFile(let path, let certificatePath):
            let file = UserHome.expand(path)
            guard FileManager.default.isReadableFile(atPath: file) else {
                if UserHome.isSandboxed {
                    return .needsSetup("Relay can\u{2019}t read \(possessive) key file (\(path)). Give Relay access to your .ssh folder in Settings \u{25B8} Hosts.")
                }
                return .needsSetup(FileManager.default.fileExists(atPath: file)
                    ? "Relay can\u{2019}t read \(possessive) key file (\(path))."
                    : "\(possessive.prefix(1).uppercased() + possessive.dropFirst()) key file (\(path)) isn\u{2019}t there.")
            }
            credentials = .keyFile(path: path, certificatePath: certificatePath?.isEmpty == false ? certificatePath : nil)
        case .password:
            guard let secret = password(host.alias), !secret.isEmpty else {
                return .needsSetup("No password for \(visited.isEmpty ? "this host" : "\u{201C}\(host.alias)\u{201D}") is saved on this device.")
            }
            credentials = .password(secret)
        case .storedKey(let id):
            guard hasStoredKey(id) else {
                return .needsSetup("\(subject) signs in with a Relay key that isn\u{2019}t on this device.")
            }
            credentials = .storedKey(id: id)
        }
        var target = SSHTarget(
            host: host.hostname,
            port: host.port ?? 22,
            username: host.user ?? NSUserName(),
            credentials: credentials)
        if let jumpAlias = host.proxyJump {
            guard !visited.contains(jumpAlias), jumpAlias != host.alias else {
                return .needsSetup("This host\u{2019}s jump hosts lead back to it.")
            }
            guard let jump = hosts(jumpAlias) else {
                return .needsSetup("\(subject)\u{2019}s jump host \u{201C}\(jumpAlias)\u{201D} isn\u{2019}t in Relay.")
            }
            switch connection(for: jump, hosts: hosts, password: password, hasStoredKey: hasStoredKey, visited: visited + [host.alias]) {
            case .needsSetup(let reason):
                return .needsSetup(reason)
            case .ready(var hop):
                let before = hop.jumps
                hop.jumps = []
                target.jumps = before + [hop]
            }
        }
        return .ready(target)
    }

    private func password(for alias: String) -> String? {
        if let cached = lock.withLock({ passwords[alias] }) { return cached }
        let value = passwordLookup(alias)
        lock.withLock { passwords[alias] = .some(value) }
        return value
    }

    /// Host settings or saved passwords changed: forget cached passwords so
    /// the next command re-evaluates every host.
    public func hostsChanged() {
        lock.withLock { passwords = [:] }
    }

    /// The "needs setup" reason for a connection failure, or nil when it's
    /// an ordinary one (unreachable, dropped).
    public static func setupReason(for error: SSHClientError, host: SSHHost?) -> String? {
        switch error {
        case .hostKeyNotTrusted(.unknown, _):
            return "This host\u{2019}s identity isn\u{2019}t trusted on this device yet."
        case .hostKeyNotTrusted:
            return "This host\u{2019}s identity has changed since Relay last connected."
        case .authenticationFailed:
            switch host?.auth {
            case .storedKey: return "The host didn\u{2019}t accept this device\u{2019}s Relay key."
            case .password: return "The host didn\u{2019}t accept the saved password."
            case .keyFile: return "The host didn\u{2019}t accept the key file."
            case .automatic, nil: return "The host didn\u{2019}t accept any of this Mac\u{2019}s keys."
            }
        case .unreachable, .connectionLost, .handshakeFailed, .channelFailed:
            return nil
        }
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
