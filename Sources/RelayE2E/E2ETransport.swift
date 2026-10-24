import Foundation
import RelayCore

/// Which SSH transport the run exercises. Default: the system ssh with the
/// user's own config (the harness's original behavior). With
/// `RELAY_E2E_BUILTIN_SSH=1`: every `~/.ssh/config` alias imported into a
/// throwaway host registry and management commands routed through the
/// built-in client, as the app does with the setting on.
enum E2ETransport {
    nonisolated(unsafe) private static var registry: SSHHostRegistry?
    nonisolated(unsafe) private static var router: BuiltInSSHRouter?

    static func setUp() async {
        guard ProcessInfo.processInfo.environment["RELAY_E2E_BUILTIN_SSH"] == "1" else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-e2e-\(UUID().uuidString)")
        let registry = SSHHostRegistry(configFile: dir.appendingPathComponent("ssh_config"))
        var hosts: [SSHHost] = []
        for alias in SSHConfigDiscovery.discoverAliases() where SSHHost.isValidAlias(alias) {
            hosts.append(await SSHConfigImporter.importHost(alias: alias))
        }
        registry.setHosts(hosts)
        self.registry = registry
        self.router = BuiltInSSHRouter(registry: registry, isEnabled: { true }, passwordLookup: { _ in nil })
        print("transport: built-in SSH client (\(hosts.count) hosts imported)")
    }

    static func runner() -> SSHCommandRunner {
        SSHCommandRunner(configFile: registry?.configFile.path, builtIn: router)
    }

    static func provider() -> SSHTmuxRuntimeProvider {
        SSHTmuxRuntimeProvider(hostRegistry: registry, builtInSSH: router)
    }
}
