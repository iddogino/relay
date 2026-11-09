import Foundation
import Security
import SystemConfiguration

/// Which build this is. The dev variant ("Relay Dev", built with
/// `RELAY_VARIANT=dev Scripts/build-app.sh`) installs alongside the real
/// app: its own bundle ID (so its own UserDefaults and Keychain items), its
/// own data folder, and no auto-updates.
public enum AppVariant {
    /// Folder under Application Support holding state.json and generated
    /// config files.
    static let dataDirectoryName: String =
        Bundle.main.object(forInfoDictionaryKey: "RelayDataDirectory") as? String ?? "Relay"

    static let dataDirectory: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataDirectoryName, isDirectory: true)

    /// Where the dev-only automation hooks read requests and write results:
    /// the data folder, except in a sandboxed dev build, whose container
    /// other tools can't reach — the build script then names a folder the
    /// build's sandbox exempts (`RelayDevHookDirectory`).
    static let devHookDirectory: URL = {
        if let path = Bundle.main.object(forInfoDictionaryKey: "RelayDevHookDirectory") as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return dataDirectory
    }()

    /// Builds without a feed (the dev variant) never check for updates —
    /// a dev build must not replace itself with a release.
    public static let updatesEnabled: Bool =
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    static let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.iddogino.Relay"

    /// The Keychain access group Relay's SSH keys live in — set by the
    /// build script only when the app is signed with an entitlement for
    /// it. nil (ad-hoc builds): no iCloud Keychain, Secure Enclave keys
    /// only.
    static let keychainAccessGroup: String? = {
        let group = Bundle.main.object(forInfoDictionaryKey: "RelayKeychainAccessGroup") as? String
        return group?.isEmpty == false ? group : nil
    }()

    /// The iCloud container hosts and projects sync through — named by the
    /// build script only when the app is signed for it. Checked against
    /// the signature too: CloudKit stops an app that uses a container it
    /// isn't entitled to. nil: this build can't sync.
    static let cloudKitContainer: String? = {
        guard let container = Bundle.main.object(forInfoDictionaryKey: "RelayCloudKitContainer") as? String,
              !container.isEmpty,
              let task = SecTaskCreateFromSelf(nil),
              let entitled = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              entitled.contains(container) else { return nil }
        return container
    }()

    /// This Mac's name, as in System Settings ▸ General ▸ Sharing.
    static var computerName: String {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "this Mac"
    }

    /// Where this Mac's own sshd listens: 22 (Remote Login). A dev build
    /// can be pointed at a test sshd instead (`RELAY_LOCAL_SSH_PORT`, or
    /// `RelayLocalSSHPort` in its defaults), to try This Mac without turning Remote Login on.
    static let localSSHPort: Int = {
        guard bundleIdentifier.hasSuffix(".dev") else { return 22 }
        let port = Int(ProcessInfo.processInfo.environment["RELAY_LOCAL_SSH_PORT"] ?? "")
            ?? UserDefaults.standard.integer(forKey: "RelayLocalSSHPort")
        return (1...65535).contains(port) ? port : 22
    }()

    /// Relay's own known_hosts: host keys trusted in Relay (the user's
    /// ~/.ssh/known_hosts is read but never written by the built-in client).
    static let knownHostsFile: URL = dataDirectory.appendingPathComponent("known_hosts")
}
