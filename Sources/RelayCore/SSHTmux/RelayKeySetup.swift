import Foundation
import RelaySSH

/// Puts one of Relay's keys on a host — sign in once (password, agent, key
/// file), add the key to `~/.ssh/authorized_keys`, prove it works — and
/// returns the host set to sign in with it from then on.
///
/// The key is tried first: a synced key another device already added, or
/// an imported key the host already trusts, needs no sign-in at all.
public final class RelayKeySetup: Sendable {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// The key file to import is passphrase-protected.
        case needsPassphrase
        case wrongPassphrase
        case keyFile(String)
        /// The host's key isn't known; `trust(…)` it (after the user agrees)
        /// and run again.
        case unknownHostKey(presentedKey: String)
        case changedHostKey
        /// The one-time sign-in was refused.
        case signInFailed(String)
        /// The key was added, but the host still refuses it (keys managed
        /// elsewhere, certificates only…).
        case keyNotAccepted
        case unreachable(String)
        /// ProxyJump and friends: the built-in client can't reach it.
        case needsDirectConnection
        case keyStore(String)
        case remoteFailed(String)

        public var errorDescription: String? {
            switch self {
            case .needsPassphrase: return "This key file is protected by a passphrase."
            case .wrongPassphrase: return "That passphrase doesn't unlock the key."
            case .keyFile(let detail): return "Couldn't read the key file: \(detail)"
            case .unknownHostKey: return "You haven't connected to this host from Relay before, so its identity can't be checked yet."
            case .changedHostKey: return "This host's identity has changed since you last connected. Relay won't send it anything."
            case .signInFailed(let detail): return "The host refused the sign-in. \(detail)"
            case .keyNotAccepted: return "The key was added, but the host still doesn't accept it. It may manage keys centrally or accept only certificates — use Sync with iCloud Keychain, or your current sign-in."
            case .unreachable(let detail): return "Couldn't connect. \(detail)"
            case .needsDirectConnection: return "Relay keys need a host Relay can reach directly; ProxyJump and similar settings aren't supported yet."
            case .keyStore(let detail): return detail
            case .remoteFailed(let detail): return "Couldn't add the key on the host.\n\(detail)"
            }
        }
    }

    public struct Request: Sendable {
        /// Where to connect. Its `auth` is how to sign in this once (not a
        /// stored key).
        public var host: SSHHost
        /// For a `.password` sign-in.
        public var password: String?
        public var storage: SSHKeyInfo.Storage
        /// With `.iCloudKeychain`: copy this existing key into iCloud
        /// Keychain, instead of using Relay's shared key.
        public var importKeyFile: String?
        public var passphrase: String?

        public init(
            host: SSHHost, password: String? = nil, storage: SSHKeyInfo.Storage,
            importKeyFile: String? = nil, passphrase: String? = nil
        ) {
            self.host = host
            self.password = password
            self.storage = storage
            self.importKeyFile = importKeyFile
            self.passphrase = passphrase
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// The host, now signing in with `key`.
        public let host: SSHHost
        public let key: SSHKeyInfo
        /// Whether the key had to be added (false: the host already took it).
        public let added: Bool
    }

    let store: any SSHKeyStore
    let pool: SSHConnectionPool
    let trustedHostsFile: String?
    /// Runs a script through the system ssh, for one-time sign-ins the
    /// built-in client can't do (certificates). nil where there's none.
    let systemSSH: (@Sendable (SSHHost, String) async throws -> SSHCommandRunner.CommandResult)?

    public init(
        store: any SSHKeyStore,
        pool: SSHConnectionPool,
        trustedHostsFile: String?,
        systemSSH: (@Sendable (SSHHost, String) async throws -> SSHCommandRunner.CommandResult)? = nil
    ) {
        self.store = store
        self.pool = pool
        self.trustedHostsFile = trustedHostsFile
        self.systemSSH = systemSSH
    }

    public func run(_ request: Request) async throws -> Outcome {
        guard request.host.inheritedOptions.isEmpty else { throw Failure.needsDirectConnection }
        let key = try resolveKey(request)
        var host = request.host
        host.auth = .storedKey(id: key.id)
        guard let keyTarget = BuiltInSSHRouter.target(for: host, password: { nil }) else {
            throw Failure.needsDirectConnection
        }

        if try await keyWorks(keyTarget) {
            return Outcome(host: host, key: key, added: false)
        }
        try await install(key, request: request)
        guard try await keyWorks(keyTarget) else { throw Failure.keyNotAccepted }
        return Outcome(host: host, key: key, added: true)
    }

    /// Records the host key a run reported as unknown as trusted (in
    /// Relay's own known_hosts).
    public func trust(host: SSHHost, presentedKey: String) throws {
        guard let trustedHostsFile else { return }
        try KnownHosts.trust(host: host.hostname, port: host.port ?? 22, presentedKey: presentedKey, in: trustedHostsFile)
    }

    private func resolveKey(_ request: Request) throws -> SSHKeyInfo {
        do {
            switch request.storage {
            case .secureEnclave:
                return try store.deviceKey()
            case .iCloudKeychain:
                guard let path = request.importKeyFile else { return try store.syncedKey() }
                let text: String
                do { text = try OpenSSHKeyFile.contents(ofFileAt: path) } catch {
                    throw Failure.keyFile("it isn't readable.")
                }
                if OpenSSHKeyFile.isEncrypted(text), (request.passphrase ?? "").isEmpty { throw Failure.needsPassphrase }
                let material: SSHPrivateKeyMaterial
                do {
                    material = try OpenSSHKeyFile.read(text, passphrase: request.passphrase)
                } catch OpenSSHKeyFile.KeyFileError.wrongPassphrase {
                    throw Failure.wrongPassphrase
                } catch OpenSSHKeyFile.KeyFileError.unsupportedKeyType(let type) {
                    throw Failure.keyFile("\(type) keys aren't supported — use an Ed25519 or ECDSA key, or let Relay make one.")
                } catch OpenSSHKeyFile.KeyFileError.unsupportedCipher(let cipher) {
                    throw Failure.keyFile("it's encrypted with \(cipher), which Relay can't read.")
                } catch OpenSSHKeyFile.KeyFileError.notOpenSSHFormat {
                    throw Failure.keyFile("it isn't an OpenSSH private key (convert it with ssh-keygen -p -f <file>).")
                } catch {
                    throw Failure.keyFile("it isn't a valid key.")
                }
                return try store.importSynced(material, name: (path as NSString).lastPathComponent)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.keyStore(error.localizedDescription)
        }
    }

    /// Whether the host accepts `target`'s stored key; throws for problems
    /// that aren't about the key.
    private func keyWorks(_ target: SSHTarget) async throws -> Bool {
        do {
            try await pool.verifyLogin(target: target)
            return true
        } catch let error as SSHClientError {
            switch error {
            case .authenticationFailed:
                return false
            default:
                throw Self.failure(for: error)
            }
        }
    }

    private func install(_ key: SSHKeyInfo, request: Request) async throws {
        let script = SSHKeyInstaller.installScript(key: key)
        let result: SSHCommandRunner.CommandResult
        if let target = BuiltInSSHRouter.target(for: request.host, password: { request.password }) {
            do {
                let exec = try await pool.exec(
                    target: target, command: "/bin/sh -s", stdin: Data(script.utf8), timeout: .seconds(30))
                result = SSHCommandRunner.CommandResult(
                    exitCode: exec.exitCode,
                    stdout: String(decoding: exec.stdout, as: UTF8.self),
                    stderr: String(decoding: exec.stderr, as: UTF8.self))
            } catch SSHClientError.authenticationFailed {
                throw Failure.signInFailed(Self.signInHint(for: request.host.auth))
            } catch let error as SSHClientError {
                throw Self.failure(for: error)
            } catch SSHConnectionPool.ExecError.timedOut {
                throw Failure.unreachable("The host stopped responding.")
            }
        } else if let systemSSH {
            result = try await systemSSH(request.host, script)
            if result.exitCode == 255 {
                throw Failure.signInFailed(SSHTmuxRuntimeProvider.sanitizedStderr(result.stderr))
            }
        } else {
            throw Failure.signInFailed("Relay can't sign in to this host with these settings.")
        }
        guard result.exitCode == 0, ["added", "present"].contains(result.markers()[SSHTmuxScripts.Marker.status]) else {
            throw Failure.remoteFailed(SSHTmuxRuntimeProvider.sanitizedStderr(result.stderr))
        }
    }

    static func signInHint(for auth: SSHHostAuth) -> String {
        switch auth {
        case .password: return "Check the user and password."
        case .keyFile: return "Check the user and key file."
        case .automatic: return "Check the user, and that your SSH agent holds a key this host accepts."
        case .storedKey: return ""
        }
    }

    static func failure(for error: SSHClientError) -> Failure {
        switch error {
        case .hostKeyNotTrusted(.unknown, let presented): return .unknownHostKey(presentedKey: presented)
        case .hostKeyNotTrusted: return .changedHostKey
        case .authenticationFailed: return .signInFailed("")
        case .unreachable(let detail): return .unreachable(detail)
        case .handshakeFailed(let detail), .channelFailed(let detail): return .unreachable(detail)
        case .connectionLost: return .unreachable("The connection dropped.")
        }
    }
}

extension RelayKeySetup {
    /// Runs a script through the system ssh with a throwaway config holding
    /// just the host (as Test Connection does) — for one-time sign-ins only
    /// it can do, like certificates.
    public static func systemSSHRunner(
        userConfigPath: String = SSHConfigDiscovery.defaultConfigPath
    ) -> @Sendable (SSHHost, String) async throws -> SSHCommandRunner.CommandResult {
        { host, script in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-keysetup-\(UUID().uuidString)")
            let config = directory.appendingPathComponent("ssh_config")
            SSHHostRegistry.writePrivately(
                SSHHostRegistry.render(hosts: [host], userConfigPath: userConfigPath, systemConfigPath: "/etc/ssh/ssh_config"),
                to: config)
            defer { try? FileManager.default.removeItem(at: directory) }
            return try await SSHCommandRunner.runProcess(
                executable: SSHCommandRunner.sshPath,
                arguments: ["-F", config.path, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", "--", host.alias, "/bin/sh -s"],
                stdin: script,
                timeout: .seconds(30))
        }
    }
}

/// The remote side of Relay keys: adding to, listing and removing from
/// `~/.ssh/authorized_keys`. Scripts run via `/bin/sh -s`.
public enum SSHKeyInstaller {
    /// Appends `key`'s line unless the key is already there (any comment or
    /// options). Creates `~/.ssh` and the file private if missing; never
    /// changes an existing file's permissions. Reports `RTERM_STATUS=added`
    /// or `present`.
    public static func installScript(key: SSHKeyInfo) -> String {
        """
        set -eu
        umask 077
        d="$HOME/.ssh"
        f="$d/authorized_keys"
        mkdir -p "$d"
        [ -f "$f" ] || : > "$f"
        if grep -qF -- \(POSIXShellQuote.quote(key.publicKeyBlob)) "$f"; then
          printf 'RTERM_STATUS=present\\n'
          exit 0
        fi
        if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\\n' >> "$f"; fi
        printf '%s\\n' \(POSIXShellQuote.quote(key.authorizedKeysLine)) >> "$f"
        printf 'RTERM_STATUS=added\\n'
        """
    }

    /// Prints the authorized_keys file after a marker line (empty when it
    /// doesn't exist).
    public static let listScript = """
        f="$HOME/.ssh/authorized_keys"
        printf 'RTERM_STATUS=ok\\n'
        printf 'RTERM_KEYS_BEGIN\\n'
        [ -f "$f" ] && cat "$f"
        exit 0
        """

    /// Drops every line holding `publicKeyBlob`, rewriting the file in
    /// place (same file, owner and mode).
    public static func removeScript(publicKeyBlob: String) -> String {
        """
        set -eu
        umask 077
        f="$HOME/.ssh/authorized_keys"
        if [ ! -f "$f" ]; then printf 'RTERM_STATUS=ok\\n'; exit 0; fi
        tmp="$f.relay-$$"
        grep -vF -- \(POSIXShellQuote.quote(publicKeyBlob)) "$f" > "$tmp" || true
        cat "$tmp" > "$f"
        rm -f "$tmp"
        printf 'RTERM_STATUS=ok\\n'
        """
    }

    /// One key line of an authorized_keys file.
    public struct AuthorizedKey: Sendable, Hashable {
        /// `<algorithm> <base64 blob>`.
        public let publicKey: String
        public let comment: String

        public var publicKeyBlob: String {
            publicKey.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        }

        /// Added by Relay (its comment says so).
        public var isRelayKey: Bool { comment.hasPrefix("relay (") }
    }

    /// The keys in a `listScript` run's output. Pure; unit-tested.
    public static func parseList(_ output: String) -> [AuthorizedKey] {
        guard let range = output.range(of: "RTERM_KEYS_BEGIN\n") else { return [] }
        return output[range.upperBound...].split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> AuthorizedKey? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        // Options come first and may hold quoted spaces; the key is the
        // first algorithm-name field followed by base64.
        let fields = tokens(trimmed)
        for index in fields.indices.dropLast() where isKeyType(fields[index]) {
            guard Data(base64Encoded: fields[index + 1]) != nil else { continue }
            let comment = fields[(index + 2)...].joined(separator: " ")
            return AuthorizedKey(publicKey: "\(fields[index]) \(fields[index + 1])", comment: comment)
        }
        return nil
    }

    private static func isKeyType(_ field: String) -> Bool {
        field.hasPrefix("ssh-") || field.hasPrefix("ecdsa-sha2-") || field.hasPrefix("sk-")
    }

    private static func tokens(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for char in line {
            if char == "\"" { quoted.toggle(); current.append(char); continue }
            if (char == " " || char == "\t") && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
