import Crypto
import Foundation

/// Host key verification against OpenSSH `known_hosts` files — the
/// user's own (read when Relay can: always outside the App Sandbox, once
/// granted in it), so a host trusted for ssh is trusted here. The only file ever written is Relay's own (`trust(…)`), for hosts
/// the user trusts in Relay.
public struct KnownHosts: Sendable {
    public enum Verdict: Sendable, Equatable {
        case trusted
        /// Known with a different key of the same type: possible MITM.
        case changed
        case revoked
        /// No entry for this host and key type.
        case unknown
    }

    struct Entry: Sendable, Equatable {
        enum Marker: Sendable { case none, revoked, certAuthority }
        let marker: Marker
        let patterns: String
        let keyType: String
        let key: Data
    }

    let entries: [Entry]

    public static let defaultFiles = [
        "~/.ssh/known_hosts",
        "~/.ssh/known_hosts2",
        "/etc/ssh/ssh_known_hosts",
        "/etc/ssh/ssh_known_hosts2",
    ]

    public static func load(files: [String] = defaultFiles) -> KnownHosts {
        var entries: [Entry] = []
        for file in files {
            let path = UserHome.expand(file)
            // Lossy: one byte that isn't UTF-8 (a Latin-1 comment) must not
            // drop the whole file, its @revoked lines included.
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            entries += parse(String(decoding: data, as: UTF8.self))
        }
        return KnownHosts(entries: entries)
    }

    /// Records `presentedKey` (`<type> <base64>`, as a refused handshake
    /// reports it) as trusted for host:port in `file` — Relay's own
    /// known_hosts, never the user's.
    public static func trust(host: String, port: Int, presentedKey: String, in file: String) throws {
        let fields = presentedKey.split(separator: " ")
        // One line, whatever the key came from (keys arrive synced from
        // other devices too): a plain algorithm name, base64, a plain host.
        guard fields.count >= 2, Data(base64Encoded: String(fields[1])) != nil,
              fields[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-@.".contains($0)) }),
              !host.isEmpty,
              // Nothing known_hosts would read as a pattern, a marker, a
              // hashed name or a comment: the line must name this host only.
              !host.contains(where: { $0.isWhitespace || $0.isNewline || ",*?!|@#".contains($0) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let path = UserHome.expand(file)
        let line = "\(lookupName(host: host, port: port)) \(fields[0]) \(fields[1])\n"
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    /// `SHA256:<base64, unpadded>` of a `<type> <base64>` key, as
    /// `ssh-keygen -l` prints it.
    public static func fingerprint(ofPublicKey publicKey: String) -> String? {
        let fields = publicKey.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            var marker = Entry.Marker.none
            if first.hasPrefix("@") {
                switch first {
                case "@revoked": marker = .revoked
                case "@cert-authority": marker = .certAuthority
                default: continue
                }
                fields.removeFirst()
            }
            guard fields.count >= 3, let key = Data(base64Encoded: fields[2]) else { continue }
            entries.append(Entry(marker: marker, patterns: fields[0], keyType: fields[1], key: key))
        }
        return entries
    }

    /// The name OpenSSH looks a host up under: the hostname, or
    /// `[hostname]:port` off port 22.
    public static func lookupName(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// The keys trusted for host:port, as `<type> <base64>` (sorted, no
    /// duplicates, revoked keys left out): what another device needs to
    /// trust the host too.
    public func trustedKeys(host: String, port: Int) -> [String] {
        let name = Self.lookupName(host: host, port: port).lowercased()
        let matching = entries.filter { Self.matches(patterns: $0.patterns, name: name) }
        let revoked = Set(matching.filter { $0.marker == .revoked }.map(\.key))
        let keys = matching
            .filter { $0.marker == .none && !revoked.contains($0.key) }
            .map { "\($0.keyType) \($0.key.base64EncodedString())" }
        return Array(Set(keys)).sorted()
    }

    /// `keyType`/`key` as in an OpenSSH public key line (algorithm name and
    /// decoded blob).
    ///
    /// A host known by keys of other types only is `.changed`, not
    /// `.unknown`: the client asks for the types it knows the host by
    /// first (`knownKeyTypes`), so a server that still had one of those
    /// keys would have presented it. Calling that a new host would let
    /// someone in between swap a blocked "identity changed" for a
    /// harmless-looking first-time prompt, just by offering another type.
    public func verify(host: String, port: Int, keyType: String, key: Data) -> Verdict {
        let name = Self.lookupName(host: host, port: port).lowercased()
        var sawKey = false
        var trusted = false
        for entry in entries where Self.matches(patterns: entry.patterns, name: name) {
            switch entry.marker {
            case .revoked:
                if entry.key == key { return .revoked }
            case .certAuthority:
                continue
            case .none:
                // Only keys the host could have been asked for count:
                // one known by an RSA key alone (which this client can't
                // check) presenting another type is not a change.
                if entry.keyType == keyType || Self.negotiableKeyTypes.contains(entry.keyType) { sawKey = true }
                if entry.keyType == keyType, entry.key == key { trusted = true }
            }
        }
        if trusted { return .trusted }
        return sawKey ? .changed : .unknown
    }

    /// The host key types the client can negotiate (NIOSSH's).
    static let negotiableKeyTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]

    /// The key types host:port is known by (revoked keys left out): what
    /// to ask the server for first.
    public func knownKeyTypes(host: String, port: Int) -> [String] {
        var types: [String] = []
        for key in trustedKeys(host: host, port: port) {
            let type = String(key.prefix { $0 != " " })
            if Self.negotiableKeyTypes.contains(type), !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// OpenSSH host-pattern semantics: comma-separated globs (`*`, `?`),
    /// `!` negation that vetoes the whole line, or a hashed
    /// `|1|salt|HMAC-SHA1(salt, name)` entry.
    static func matches(patterns: String, name: String) -> Bool {
        if patterns.hasPrefix("|1|") {
            let parts = patterns.split(separator: "|", omittingEmptySubsequences: true)
            guard parts.count == 3, parts[0] == "1",
                  let salt = Data(base64Encoded: String(parts[1])),
                  let hash = Data(base64Encoded: String(parts[2])) else { return false }
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
            return Data(mac) == hash
        }
        var matched = false
        for pattern in patterns.lowercased().split(separator: ",") {
            if pattern.hasPrefix("!") {
                if glob(pattern.dropFirst(), name[...]) { return false }
            } else if glob(pattern, name[...]) {
                matched = true
            }
        }
        return matched
    }

    static func glob(_ pattern: Substring, _ text: Substring) -> Bool {
        guard let p = pattern.first else { return text.isEmpty }
        switch p {
        case "*":
            // Any suffix of the text (including the empty one) may follow.
            return text.indices.contains { glob(pattern.dropFirst(), text[$0...]) }
                || glob(pattern.dropFirst(), text[text.endIndex...])
        case "?":
            return !text.isEmpty && glob(pattern.dropFirst(), text.dropFirst())
        default:
            return text.first == p && glob(pattern.dropFirst(), text.dropFirst())
        }
    }
}
