import Foundation

/// Resolves an SSH alias to the effective `HostName` the way ssh itself
/// would, via `ssh -G` (local config evaluation only — no connection).
/// Used so rewritten localhost links point at a name the client's browser
/// can actually resolve, even when the alias is not itself a DNS name.
public enum SSHHostNameResolver {
    /// Parses `ssh -G` output for the effective hostname. Pure; unit-tested.
    public static func parseHostName(fromConfigDump output: String) -> String? {
        for line in output.split(separator: "\n") {
            // Format: "hostname <value>" (lowercase key, single space).
            if line.hasPrefix("hostname ") {
                let value = String(line.dropFirst("hostname ".count))
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Resolves the alias, falling back to the alias itself when `ssh -G`
    /// fails or resolves to a loopback address (tunnel-style configs where
    /// the real endpoint is not reachable by name from a browser anyway).
    public static func resolve(alias: String) async -> String {
        let result = try? await SSHCommandRunner.runProcess(
            executable: SSHCommandRunner.sshPath,
            arguments: ["-G", "--", alias],
            stdin: nil,
            timeout: .seconds(5)
        )
        guard let result, result.exitCode == 0,
              let hostname = parseHostName(fromConfigDump: result.stdout),
              !LocalhostURLRewriter.isLoopbackHost(hostname)
        else { return alias }
        return hostname
    }
}
