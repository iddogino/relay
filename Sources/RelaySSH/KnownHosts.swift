import Crypto
import Foundation

/// Host key verification against OpenSSH `known_hosts` files — the same
/// trust store the system ssh uses, so a host trusted there is trusted
/// here (and vice versa: nothing is ever written by this type).
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
            let path = (file as NSString).expandingTildeInPath
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            entries += parse(text)
        }
        return KnownHosts(entries: entries)
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

    /// `keyType`/`key` as in an OpenSSH public key line (algorithm name and
    /// decoded blob).
    public func verify(host: String, port: Int, keyType: String, key: Data) -> Verdict {
        let name = Self.lookupName(host: host, port: port).lowercased()
        var sawSameType = false
        var trusted = false
        for entry in entries where Self.matches(patterns: entry.patterns, name: name) {
            switch entry.marker {
            case .revoked:
                if entry.key == key { return .revoked }
            case .certAuthority:
                continue
            case .none:
                guard entry.keyType == keyType else { continue }
                sawSameType = true
                if entry.key == key { trusted = true }
            }
        }
        if trusted { return .trusted }
        return sawSameType ? .changed : .unknown
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
