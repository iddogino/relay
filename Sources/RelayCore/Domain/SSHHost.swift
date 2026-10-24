import Foundation

/// How Relay authenticates to a host.
public enum SSHHostAuth: Codable, Sendable, Hashable {
    /// OpenSSH's defaults: the SSH agent, then the standard key files.
    case automatic
    /// A specific private key, optionally with an OpenSSH certificate.
    case keyFile(path: String, certificatePath: String?)
    /// A password kept in the Keychain (never in the host record).
    case password
}

/// A machine Relay connects to — Relay's own record, independent of
/// `~/.ssh/config` (which is only an import source). The alias is the
/// host's identity: it's what `WorkspaceRef.opaqueID` holds, so it never
/// changes after creation.
public struct SSHHost: Codable, Sendable, Hashable, Identifiable {
    public var id: String { alias }
    public let alias: String
    public var hostname: String
    /// nil means the SSH default (22).
    public var port: Int?
    /// nil means the local username (OpenSSH's default).
    public var user: String?
    public var auth: SSHHostAuth
    /// Settings found at import that Relay doesn't model (ProxyJump, …).
    /// On the Mac they still apply — the user's ssh config is consulted
    /// after Relay's own entry — but they won't carry to other devices.
    public var inheritedOptions: [String]

    public init(
        alias: String,
        hostname: String,
        port: Int? = nil,
        user: String? = nil,
        auth: SSHHostAuth = .automatic,
        inheritedOptions: [String] = []
    ) {
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.user = user
        self.auth = auth
        self.inheritedOptions = inheritedOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decode(String.self, forKey: .alias)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        auth = try container.decodeIfPresent(SSHHostAuth.self, forKey: .auth) ?? .automatic
        inheritedOptions = try container.decodeIfPresent([String].self, forKey: .inheritedOptions) ?? []
    }

    public var workspace: WorkspaceRef { WorkspaceRef(provider: .sshTmux, opaqueID: alias) }

    /// `user@hostname:port`, eliding defaults — for captions.
    public var summary: String {
        var text = hostname
        if let user, !user.isEmpty { text = "\(user)@\(text)" }
        if let port, port != 22 { text += ":\(port)" }
        return text
    }

    // MARK: Validation

    public enum ValidationError: Error, Equatable, LocalizedError {
        case alias, hostname, port, user, keyPath

        public var errorDescription: String? {
            switch self {
            case .alias: return "The name can use letters, digits, dots, dashes and underscores, and can't start with a dash."
            case .hostname: return "Enter a hostname or IP address (no spaces)."
            case .port: return "The port must be between 1 and 65535."
            case .user: return "The username can't contain spaces or quotes."
            case .keyPath: return "Choose a key file."
            }
        }
    }

    /// Every field lands in a generated ssh config (and, for the alias,
    /// on ssh command lines), so the accepted shapes are deliberately
    /// narrow: nothing that could be read as a pattern, an option, a
    /// token (`%h`), or a second directive.
    public func validate() throws {
        guard Self.isValidAlias(alias) else { throw ValidationError.alias }
        guard Self.isValidHostname(hostname) else { throw ValidationError.hostname }
        if let port, !(1...65535).contains(port) { throw ValidationError.port }
        if let user, !user.isEmpty, !Self.isPlainToken(user) { throw ValidationError.user }
        if case .keyFile(let path, let certificate) = auth {
            guard Self.isValidPath(path) else { throw ValidationError.keyPath }
            if let certificate, !certificate.isEmpty, !Self.isValidPath(certificate) { throw ValidationError.keyPath }
        }
    }

    public static func isValidAlias(_ alias: String) -> Bool {
        guard let first = alias.first, first != "-", alias.count <= 128 else { return false }
        return alias.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    static func isValidHostname(_ hostname: String) -> Bool {
        guard let first = hostname.first, first != "-", hostname.count <= 255 else { return false }
        // Letters, digits, dots, dashes, underscores; colons and brackets
        // for IPv6 literals.
        return hostname.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-:[]".contains($0)) }
    }

    static func isPlainToken(_ value: String) -> Bool {
        guard value.first != "-" else { return false }
        return value.allSatisfy { char in
            !char.isWhitespace && char != "\"" && char != "'" && char != "%" && char != "\\"
                && !char.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }

    static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") || path.hasPrefix("~/") else { return false }
        return !path.contains("\"") && !path.contains("\\")
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
