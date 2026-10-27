import Foundation

/// The name a browser on this device should use for a host, so rewritten
/// localhost links point at something it can resolve even when the alias
/// is not itself a DNS name.
public enum SSHHostNameResolver {
    /// The host's hostname — or its alias when there's no record, or the
    /// hostname is a loopback address (tunnel-style setups where the real
    /// endpoint isn't reachable by name from a browser anyway). Pure;
    /// unit-tested.
    public static func browserHost(alias: String, host: SSHHost?) -> String {
        guard let hostname = host?.hostname, !hostname.isEmpty,
              !LocalhostURLRewriter.isLoopbackHost(hostname) else { return alias }
        return hostname
    }
}
