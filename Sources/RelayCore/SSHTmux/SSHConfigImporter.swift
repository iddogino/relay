import Foundation

/// Turns an `~/.ssh/config` alias into Relay host records, using the
/// values OpenSSH itself would connect with — the config evaluated in-app
/// (`SSHConfigEvaluator`, in `ssh -G`'s output format: Include, Match and
/// `Host *` defaults applied), since Relay can't run ssh.
public enum SSHConfigImporter {
    /// Key files OpenSSH tries when a config names none. `ssh -G` lists
    /// all of them in that case, and only the configured ones otherwise.
    static let defaultIdentityFiles: Set<String> = [
        "~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ecdsa_sk",
        "~/.ssh/id_ed25519", "~/.ssh/id_ed25519_sk", "~/.ssh/id_xmss", "~/.ssh/id_dsa",
    ]

    /// Imports `alias` and the jump hosts it connects through (each its own
    /// Relay host, linked by `proxyJump`), the alias first. `evaluate`
    /// gives an alias's effective config, `ssh -G`-style (nil when it
    /// can't); jump hosts already in `existing` are linked, not imported
    /// again. Pure apart from `evaluate`; unit-tested.
    public static func importHosts(
        alias: String,
        existing: Set<String> = [],
        evaluate: (String) -> String?
    ) -> [SSHHost] {
        var imported: [SSHHost] = []
        var taken = existing
        importOne(alias, user: nil, port: nil, evaluate: evaluate, taken: &taken, imported: &imported)
        return imported
    }

    /// Imports `alias` — then the jump hosts it goes through, each with its
    /// own config (as OpenSSH connects to a jump host), so their own jump
    /// hosts come along too.
    private static func importOne(
        _ alias: String, user: String?, port: Int?, evaluate: (String) -> String?,
        taken: inout Set<String>, imported: inout [SSHHost]
    ) {
        let config = evaluate(alias)
        var host = config.map { Self.host(alias: alias, effectiveConfig: $0) } ?? SSHHost(alias: alias, hostname: alias)
        if let user { host.user = user }
        if let port { host.port = port == 22 ? nil : port }
        taken.insert(alias)
        let index = imported.count
        imported.append(host)

        let hops = config.map(jumpHops(fromEffectiveConfig:)) ?? []
        guard !hops.isEmpty else { return }
        guard hops.allSatisfy({ SSHHost.isValidAlias($0.host) }) else {
            imported[index].inheritedOptions.append("ProxyJump \(hops.map(\.spec).joined(separator: ","))")
            return
        }
        // Each hop after the first is reached through the one before it.
        var previous: String?
        for hop in hops {
            if !taken.contains(hop.host) {
                let hopIndex = imported.count
                importOne(hop.host, user: hop.user, port: hop.port, evaluate: evaluate, taken: &taken, imported: &imported)
                if let previous { imported[hopIndex].proxyJump = previous }
            }
            previous = hop.host
        }
        imported[index].proxyJump = previous
    }

    /// A ProxyJump hop: `[user@]host[:port]`.
    struct Hop: Equatable {
        let spec: String
        let user: String?
        let host: String
        let port: Int?
    }

    /// The hops a config's ProxyJump names, in connection order — or the
    /// jump host of a ProxyCommand that only does what ProxyJump does
    /// (`ssh -W %h:%p bastion`). Pure; unit-tested.
    static func jumpHops(fromEffectiveConfig config: String) -> [Hop] {
        var proxyJump: String?
        var proxyCommand: String?
        for line in config.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            if proxyJump == nil, lower.hasPrefix("proxyjump ") { proxyJump = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces) }
            if proxyCommand == nil, lower.hasPrefix("proxycommand ") { proxyCommand = String(line.dropFirst(13)).trimmingCharacters(in: .whitespaces) }
        }
        if let proxyJump, proxyJump.lowercased() != "none", !proxyJump.isEmpty {
            return proxyJump.split(separator: ",").compactMap { parseHop(String($0).trimmingCharacters(in: .whitespaces)) }
        }
        if let proxyCommand, let jump = jumpHost(fromProxyCommand: proxyCommand), let hop = parseHop(jump) {
            return [hop]
        }
        return []
    }

    /// `bastion` from `ssh -W %h:%p bastion` (and `-q`, `[%h]:%p`,
    /// `/usr/bin/ssh`, `exec ssh …`); nil for anything else. Pure.
    static func jumpHost(fromProxyCommand command: String) -> String? {
        var words = command.split(separator: " ").map(String.init)
        if words.first == "exec" { words.removeFirst() }
        guard let program = words.first, program == "ssh" || program.hasSuffix("/ssh") else { return nil }
        words.removeFirst()
        var host: String?
        var sawForward = false
        var index = 0
        while index < words.count {
            let word = words[index]
            switch word {
            case "-W":
                guard index + 1 < words.count, ["%h:%p", "[%h]:%p"].contains(words[index + 1]) else { return nil }
                sawForward = true
                index += 2
            case "-q", "-T", "-x", "-a":
                index += 1
            default:
                guard !word.hasPrefix("-"), host == nil else { return nil }
                host = word
                index += 1
            }
        }
        return sawForward ? host : nil
    }

    static func parseHop(_ spec: String) -> Hop? {
        guard !spec.isEmpty, !spec.contains("://") else { return nil }
        var rest = Substring(spec)
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port: Int?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
            rest = rest[rest.index(after: rest.startIndex)..<close]
        } else if let colon = rest.lastIndex(of: ":"), rest.filter({ $0 == ":" }).count == 1 {
            port = Int(rest[rest.index(after: colon)...])
            rest = rest[..<colon]
        }
        guard !rest.isEmpty else { return nil }
        return Hop(spec: spec, user: user?.isEmpty == false ? user : nil, host: String(rest), port: port)
    }

    /// Builds the record from `ssh -G` output. Pure; unit-tested.
    public static func host(alias: String, effectiveConfig: String) -> SSHHost {
        var values: [String: [String]] = [:]
        for line in effectiveConfig.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space].lowercased()
            let value = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            values[key, default: []].append(value)
        }
        func first(_ key: String) -> String? { values[key]?.first }

        let hostname = first("hostname").flatMap { $0.isEmpty ? nil : $0 } ?? alias
        let port = first("port").flatMap(Int.init).flatMap { $0 == 22 ? nil : $0 }
        let user = first("user").flatMap { $0.isEmpty ? nil : $0 }

        let identities = values["identityfile"] ?? []
        let auth: SSHHostAuth
        // Several default names = nothing configured; a single default name
        // (`IdentityFile ~/.ssh/id_ed25519`) is an explicit choice.
        if identities.isEmpty || (identities.count > 1 && identities.allSatisfy { defaultIdentityFiles.contains($0) }) {
            auth = .automatic
        } else {
            let certificate = values["certificatefile"]?.first
            auth = .keyFile(path: identities[0], certificatePath: certificate)
        }

        var inherited: [String] = []
        // ProxyJump becomes jump hosts (`importHosts`), as does a
        // ProxyCommand that only does what ProxyJump does.
        if let command = first("proxycommand"), command != "none", jumpHost(fromProxyCommand: command) == nil {
            inherited.append("ProxyCommand \(command)")
        }
        for (key, label) in [("localforward", "LocalForward"), ("remoteforward", "RemoteForward"), ("dynamicforward", "DynamicForward")] {
            for value in values[key] ?? [] { inherited.append("\(label) \(value)") }
        }
        if first("forwardagent") == "yes" { inherited.append("ForwardAgent yes") }

        var host = SSHHost(alias: alias, hostname: hostname, port: port, user: user, auth: auth, inheritedOptions: inherited)
        // Whatever doesn't fit Relay's narrower field rules stays with the
        // user's config (consulted after Relay's entry), not in the record.
        if (try? host.validate()) == nil {
            if !SSHHost.isValidHostname(host.hostname) { host.hostname = alias }
            if let user = host.user, !SSHHost.isPlainToken(user) { host.user = nil }
            if case .keyFile(let path, _) = host.auth, !SSHHost.isValidPath(path) { host.auth = .automatic }
            if case .keyFile(let path, let cert?) = host.auth, !SSHHost.isValidPath(cert) {
                host.auth = .keyFile(path: path, certificatePath: nil)
            }
        }
        return host
    }
}
