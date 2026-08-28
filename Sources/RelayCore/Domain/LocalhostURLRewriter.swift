import Foundation

/// Rewrites loopback URLs clicked in a remote terminal so they point at the
/// remote machine instead of the local one. A dev server on the remote says
/// "listening on http://localhost:3000" — clicking that from the client
/// should open the remote's port 3000, not the Mac's.
///
/// Only exact loopback hosts are rewritten. `*.localhost` subdomains are
/// deliberately left alone: they usually carry virtual-host routing
/// (`app.localhost`) that a plain host swap would break.
public enum LocalhostURLRewriter {
    /// Hosts treated as "this machine" by convention. `0.0.0.0` and `::` are
    /// listen-side wildcards that servers often print verbatim.
    private static let loopbackHosts: Set<String> = [
        "localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]", "::", "[::]",
    ]

    /// Schemes for which a host rewrite is meaningful.
    private static let rewritableSchemes: Set<String> = ["http", "https", "ws", "wss"]

    public static func isRewritable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              rewritableSchemes.contains(scheme),
              let host = url.host?.lowercased()
        else { return false }
        return loopbackHosts.contains(host)
    }

    /// Returns the URL with its loopback host replaced by `remoteHost`,
    /// preserving scheme, port, path, query, fragment, and credentials.
    /// Returns nil when the URL is not rewritable or malformed.
    public static func rewrite(_ url: URL, remoteHost host: String) -> URL? {
        guard isRewritable(url), !host.isEmpty else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.host = host
        return components.url
    }

    /// True for hosts that are themselves loopback — used to reject a
    /// resolved SSH HostName that would just point back at the client
    /// (e.g. tunnel-style `HostName 127.0.0.1` configs).
    public static func isLoopbackHost(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }
}
