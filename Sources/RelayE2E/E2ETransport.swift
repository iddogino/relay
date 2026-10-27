import Foundation
import RelayCore

/// The harness's connections: every `~/.ssh/config` alias imported into a
/// throwaway host registry, connected over Relay's built-in SSH client —
/// as the app does (it has no other way to connect).
enum E2ETransport {
    nonisolated(unsafe) private static var registry = SSHHostRegistry()
    nonisolated(unsafe) private static var router: BuiltInSSHRouter?

    static func setUp() async {
        var hosts: [SSHHost] = []
        for alias in SSHConfigDiscovery.discoverAliases() where SSHHost.isValidAlias(alias) {
            guard !hosts.contains(where: { $0.alias == alias }) else { continue }
            hosts += SSHConfigImporter.importHosts(
                alias: alias, existing: Set(hosts.map(\.alias)), evaluate: SSHConfigImporter.effectiveConfig)
        }
        registry.setHosts(hosts)
        router = BuiltInSSHRouter(registry: registry, passwordLookup: { _ in nil })
        print("transport: built-in SSH client (\(hosts.count) hosts imported)")
    }

    static func host(alias: String) -> SSHHost? {
        registry.host(alias: alias)
    }

    static func runner() -> SSHCommandRunner {
        SSHCommandRunner(builtIn: router!)
    }

    static func provider() -> SSHTmuxRuntimeProvider {
        SSHTmuxRuntimeProvider(hostRegistry: registry, builtInSSH: router!)
    }
}
