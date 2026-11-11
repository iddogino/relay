#if os(macOS)
import Foundation
import Observation
import RelayCore
import RelaySSH
import SystemConfiguration

/// Setting up this Mac as a host: Relay reaches it over SSH (Remote Login)
/// like any other machine, so its sessions are real login shells outside
/// the App Sandbox — and the host syncs, so other devices see its projects.
///
/// Steps: Remote Login on → pick the name other devices use → sign in once
/// to put a Relay key on it → install tmux if it's missing.
@MainActor
@Observable
final class ThisMacSetup {
    enum Step: Equatable {
        case checking
        /// This build has no built-in SSH client to reach this Mac with.
        case unavailable
        /// Nothing answers on this Mac's SSH port.
        case remoteLoginOff
        /// Remote Login is on; name, address and sign-in to fill in.
        case details
        case working(String)
        /// Connected, but there's no tmux.
        case needsTmux(HostPlatform)
        case done(SSHHost)
    }

    private(set) var step: Step = .checking
    var errorMessage: String?

    var alias = ""
    var user = NSUserName()
    private(set) var candidates: [LocalNetworkAddresses.Candidate] = []
    var address = ""
    /// The account password, for the one sign-in that adds the Relay key.
    var password = ""
    /// Dev hook only: sign in once with this key file instead of a password
    /// (a test sshd can't check passwords).
    var bootstrapKeyFile: String?
    private(set) var installedTmux: String?

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var port: Int { model.localSSHPort }

    /// How the Relay key is kept: in iCloud Keychain when this build can,
    /// so other devices can sign in to this Mac too; otherwise in the
    /// Secure Enclave (this Mac only).
    var keyStorage: SSHKeyInfo.Storage? {
        guard let store = model.keyStore else { return nil }
        if store.canSync { return .iCloudKeychain }
        if store.canUseSecureEnclave { return .secureEnclave }
        return nil
    }

    func start() async {
        errorMessage = nil
        if let existing = model.thisMacHost {
            step = .done(existing)
            return
        }
        guard model.builtInSSH?.localIdentity != nil else {
            step = .unavailable
            return
        }
        step = .checking
        await model.refreshLocalIdentity(force: true)
        guard model.localHostKey != nil else {
            step = .remoteLoginOff
            return
        }
        if alias.isEmpty { alias = SSHHost.suggestedAlias(forComputerName: AppVariant.computerName, taken: Set(model.hosts.map(\.alias))) }
        let localName = SCDynamicStoreCopyLocalHostName(nil) as String?
        candidates = await Task.detached { LocalNetworkAddresses.candidates(localHostName: localName) }.value
        // No fallback to a loopback address: synced, it would point every
        // other device at itself.
        if address.isEmpty { address = candidates.first?.address ?? "" }
        step = .details
    }

    var canConnect: Bool {
        SSHHost.isValidAlias(alias) && !model.hosts.contains { $0.alias == alias }
            && !address.trimmingCharacters(in: .whitespaces).isEmpty && !addressIsLoopback && !user.isEmpty
            && (!password.isEmpty || bootstrapKeyFile != nil)
    }

    /// A loopback address reaches each device itself, not this Mac.
    var addressIsLoopback: Bool {
        let address = address.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return address == "localhost" || address.hasSuffix(".localhost") || address == "::1"
            || address.hasPrefix("127.") || address == "0.0.0.0"
    }

    /// Trusts this Mac's key, puts a Relay key on it, saves the host, and
    /// checks for tmux.
    func connect() async {
        guard let hostKey = model.localHostKey else {
            step = .remoteLoginOff
            return
        }
        errorMessage = nil
        let hostname = address.trimmingCharacters(in: .whitespaces)
        var host = SSHHost(alias: alias, hostname: hostname, port: port == 22 ? nil : port, user: user)
        // The key was read from this Mac's own sshd over loopback, so it
        // can be trusted without asking — under the name other devices
        // use, and for loopback (where the one-time sign-in goes).
        // Checked before anything is trusted or saved under it: a host
        // that isn't valid would be refused by every other device.
        do {
            try host.validate()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var loopback = host
        loopback.hostname = "127.0.0.1"
        loopback.port = port
        do {
            try model.trustHostKey(hostKey, for: loopback)
        } catch {
            errorMessage = "Couldn\u{2019}t save this Mac\u{2019}s identity: \(error.localizedDescription)"
            return
        }
        if let keyFile = bootstrapKeyFile {
            loopback.auth = .keyFile(path: keyFile, certificatePath: nil)
        } else {
            loopback.auth = .password
        }

        var savedPassword: String?
        if let storage = keyStorage, let setup = model.relayKeySetup() {
            step = .working("Adding a Relay key to this Mac\u{2026}")
            do {
                let outcome = try await setup.run(RelayKeySetup.Request(
                    host: loopback, password: bootstrapKeyFile == nil ? password : nil, storage: storage))
                host.auth = outcome.host.auth
            } catch {
                step = .details
                errorMessage = error.localizedDescription
                return
            }
        } else if let keyFile = bootstrapKeyFile {
            host.auth = .keyFile(path: keyFile, certificatePath: nil)
        } else {
            // No Relay key in this build: the password is saved instead.
            host.auth = .password
            savedPassword = password
        }
        // Under the name other devices use, only now that the host is
        // being saved: a failed setup leaves nothing trusted under a name
        // the user may yet change.
        do {
            try model.trustHostKey(hostKey, for: host)
        } catch {
            step = .details
            errorMessage = "Couldn\u{2019}t save this Mac\u{2019}s identity: \(error.localizedDescription)"
            return
        }
        await model.saveHost(host, password: savedPassword)
        password = ""
        await model.refreshLocalIdentity(force: true)
        await checkTmux(host)
    }

    func checkTmux(_ host: SSHHost) async {
        step = .working("Checking for tmux\u{2026}")
        do {
            let platform = try await model.probeTmux(on: host)
            step = platform.tmuxPath == nil ? .needsTmux(platform) : .done(host)
        } catch {
            errorMessage = error.localizedDescription
            step = .done(host)
        }
    }

    func installTmux(_ method: AppModel.TmuxInstallMethod) async {
        guard case .needsTmux(let platform) = step, let host = model.hosts.first(where: { $0.alias == alias }) else { return }
        errorMessage = nil
        step = .working(method == .bundled ? "Installing tmux\u{2026}" : "Installing tmux with \(platform.packageManager ?? "the package manager")\u{2026}")
        do {
            installedTmux = try await model.installTmux(on: host, method: method)
            step = .done(host)
        } catch {
            errorMessage = error.localizedDescription
            step = .needsTmux(platform)
        }
    }
}
#endif
