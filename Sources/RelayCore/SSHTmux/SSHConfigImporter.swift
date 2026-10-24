import Foundation

/// Turns an `~/.ssh/config` alias into a Relay host record, using the
/// values OpenSSH itself would connect with (`ssh -G`: Include, Match and
/// `Host *` defaults all evaluated — no hand-rolled config semantics).
public enum SSHConfigImporter {
    /// Key files OpenSSH tries when a config names none. `ssh -G` lists
    /// all of them in that case, and only the configured ones otherwise.
    static let defaultIdentityFiles: Set<String> = [
        "~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ecdsa_sk",
        "~/.ssh/id_ed25519", "~/.ssh/id_ed25519_sk", "~/.ssh/id_xmss", "~/.ssh/id_dsa",
    ]

    /// Imports one alias. Falls back to a bare record (hostname = alias)
    /// when `ssh -G` can't evaluate the config.
    public static func importHost(alias: String, configPath: String? = nil) async -> SSHHost {
        var arguments = ["-G"]
        if let configPath { arguments += ["-F", configPath] }
        arguments += ["--", alias]
        guard let result = try? await SSHCommandRunner.runProcess(
            executable: SSHCommandRunner.sshPath,
            arguments: arguments,
            stdin: nil,
            timeout: .seconds(5)),
              result.exitCode == 0
        else {
            return SSHHost(alias: alias, hostname: alias)
        }
        return host(alias: alias, effectiveConfig: result.stdout)
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
        for (key, label) in [("proxyjump", "ProxyJump"), ("proxycommand", "ProxyCommand")] {
            if let value = first(key), value != "none" { inherited.append("\(label) \(value)") }
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
