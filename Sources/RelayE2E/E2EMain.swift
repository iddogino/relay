import Foundation
import RelayCore

/// Live end-to-end acceptance harness. Drives the REAL SSHTmuxRuntimeProvider
/// against the two configured remotes (one macOS, one Ubuntu), using a
/// uniquely namespaced temp root + tmux marker per run, and cleans up fully.
///
/// Usage:
///   relay-e2e discover                 — classify reachable hosts
///   relay-e2e run                      — full acceptance run on both hosts
///   relay-e2e cleanup --state <file>   — independent cleanup after a crash
@main
struct E2EMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "discover":
            _ = try? await HostDiscovery.discoverPair(verbose: true)
        case "run":
            await E2ERun().runAll()
        case "cleanup":
            guard let index = args.firstIndex(of: "--state"), args.count > index + 1 else {
                fputs("usage: relay-e2e cleanup --state <file>\n", stderr)
                exit(2)
            }
            await E2ECleanup.cleanup(statePath: args[index + 1])
        default:
            fputs("usage: relay-e2e [discover|run|cleanup --state <file>]\n", stderr)
            exit(2)
        }
    }
}

// MARK: - Host discovery (spec §20.1)

enum HostDiscovery {
    struct Probe {
        let alias: String
        let os: String        // "darwin" | "ubuntu" | other
        let loopback: Bool
    }

    static func discoverPair(verbose: Bool) async throws -> (darwin: String, ubuntu: String) {
        let aliases = SSHConfigDiscovery.discoverAliases()
        print("discovered aliases: \(aliases.joined(separator: ", "))")

        var probes: [Probe] = []
        for alias in aliases {
            // Skip obvious non-shell hosts quickly via probe failure.
            guard let probe = await probeHost(alias) else {
                if verbose { print("  \(alias): unreachable/no shell") }
                continue
            }
            if verbose { print("  \(alias): os=\(probe.os) loopback=\(probe.loopback)") }
            probes.append(probe)
        }

        // Prefer real remote machines over loopback VMs (e.g. OrbStack).
        func pick(_ os: String) -> String? {
            (probes.first { $0.os == os && !$0.loopback } ?? probes.first { $0.os == os })?.alias
        }
        guard let darwin = pick("darwin") else {
            throw E2EError.fatal("No reachable macOS remote found.")
        }
        guard let ubuntu = pick("ubuntu") else {
            throw E2EError.fatal("No reachable Ubuntu remote found.")
        }
        print("selected: darwin=\(darwin) ubuntu=\(ubuntu)")
        return (darwin, ubuntu)
    }

    private static func probeHost(_ alias: String) async -> Probe? {
        let runner = SSHCommandRunner()
        let script = """
        printf 'os=%s\\n' "$(uname -s)"
        if [ -f /etc/os-release ]; then . /etc/os-release; printf 'id=%s\\n' "$ID"; fi
        """
        guard let result = try? await runner.runScript(alias: alias, script: script, timeout: .seconds(12)),
              result.exitCode == 0 else { return nil }
        var os = ""
        for line in result.stdout.split(separator: "\n") {
            if line.hasPrefix("os=Darwin") { os = "darwin" }
            if line.hasPrefix("id=ubuntu") { os = "ubuntu" }
        }
        guard !os.isEmpty else { return nil }

        // ssh -G resolves the effective hostname without connecting.
        var loopback = false
        if let resolved = try? await SSHCommandRunner.runProcess(
            executable: SSHCommandRunner.sshPath,
            arguments: ["-G", alias],
            stdin: nil,
            timeout: .seconds(5)) {
            for line in resolved.stdout.split(separator: "\n") where line.hasPrefix("hostname ") {
                let host = line.dropFirst("hostname ".count)
                loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
            }
        }
        return Probe(alias: alias, os: os, loopback: loopback)
    }
}

// MARK: - Run state (for crash-safe cleanup)

struct E2EHostState: Codable {
    let alias: String
    var tempRoot: String = ""
}

struct E2EState: Codable {
    let runID: String
    var hosts: [E2EHostState]
}

enum E2EError: Error {
    case fatal(String)
}

func stateDirectory() -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".e2e-state", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
