import Foundation
import RelayCore
import RelaySSH

/// This Mac as a host (Remote Login), and installing tmux on hosts.
extension AppModel {
    /// The tmux builds this app carries (Contents/Resources/tmux), if any.
    static let tmuxBundle: TmuxBundle? = Bundle.main.resourceURL
        .flatMap { TmuxBundle(directory: $0.appendingPathComponent("tmux", isDirectory: true)) }

    /// Where this Mac's sshd listens (22: Remote Login).
    var localSSHPort: Int { builtInSSH?.localIdentity?.port ?? 22 }

    /// Asks this Mac's sshd for its host key again (throttled unless
    /// `force`); hosts that are this Mac switch to loopback, or back.
    func refreshLocalIdentity(force: Bool = false) async {
        guard let builtInSSH, let identity = builtInSSH.localIdentity else { return }
        let key = await identity.refresh(pool: builtInSSH.pool, force: force)
        if key != localHostKey {
            localHostKey = key
            builtInSSH.hostsChanged()
        }
    }

    /// Whether `host` is this Mac: the key trusted for it is the one this
    /// Mac's sshd presents. Its connections then go over loopback.
    func isThisMac(_ host: SSHHost) -> Bool {
        // Read for observation: views showing this update when either does.
        guard localHostKey != nil, hosts.contains(where: { $0.alias == host.alias }) else { return false }
        return builtInSSH?.isThisMac(alias: host.alias) ?? false
    }

    /// The saved host that is this Mac, if there is one.
    var thisMacHost: SSHHost? {
        hosts.first(where: isThisMac)
    }

    /// Where `host`'s commands go: through the router (loopback when it's
    /// this Mac) when it's saved as it is, or as typed otherwise.
    func sshTarget(for host: SSHHost, password: String?) throws -> SSHTarget {
        guard let builtInSSH else { throw TmuxInstaller.Failure.failed("Relay can\u{2019}t connect to hosts here.") }
        let connection = hosts.contains(host) && password == nil
            ? builtInSSH.connection(for: host.alias)
            : builtInSSH.connection(for: host, password: password ?? SSHPasswordStore.load(alias: host.alias))
        switch connection {
        case .ready(let target): return target
        case .needsSetup(let reason): throw TmuxInstaller.Failure.failed(reason)
        }
    }

    /// What `host` is and whether it has tmux.
    func probeTmux(on host: SSHHost, password: String? = nil) async throws -> HostPlatform {
        guard let pool = builtInSSH?.pool else { throw TmuxInstaller.Failure.failed("Relay can\u{2019}t connect to hosts here.") }
        do {
            return try await TmuxInstaller.probe(target: try sshTarget(for: host, password: password), pool: pool)
        } catch let error as SSHClientError {
            throw TmuxInstaller.Failure.failed(error.description)
        }
    }

    enum TmuxInstallMethod: Equatable {
        /// Relay's own build, into ~/.relay (no sudo).
        case bundled
        /// The host's package manager, where it needs no password.
        case packageManager
    }

    /// Installs tmux on `host`; returns its `-V` line. Validations after
    /// this find it (`find_tmux` looks in ~/.relay/bin).
    func installTmux(on host: SSHHost, password: String? = nil, method: TmuxInstallMethod) async throws -> String {
        guard let pool = builtInSSH?.pool else { throw TmuxInstaller.Failure.failed("Relay can\u{2019}t connect to hosts here.") }
        let target = try sshTarget(for: host, password: password)
        do {
            let platform = try await TmuxInstaller.probe(target: target, pool: pool)
            switch method {
            case .bundled:
                guard let bundle = Self.tmuxBundle else {
                    throw TmuxInstaller.Failure.unsupported("this host: this build of Relay doesn\u{2019}t include tmux")
                }
                return try await TmuxInstaller.installBundled(
                    target: target, pool: pool, bundle: bundle, platform: platform).version
            case .packageManager:
                _ = try await TmuxInstaller.installWithPackageManager(target: target, pool: pool, platform: platform)
                return try await TmuxInstaller.probe(target: target, pool: pool).tmuxVersion ?? "tmux"
            }
        } catch let error as SSHClientError {
            throw TmuxInstaller.Failure.failed(error.description)
        }
    }
}
