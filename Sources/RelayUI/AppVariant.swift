import Foundation
import Security
#if os(macOS)
import SystemConfiguration
#else
import UIKit
#endif

/// Which build this is. The dev variant ("Relay Dev", App/project.yml's
/// Debug configuration) installs alongside the real app: its own bundle ID
/// (so its own UserDefaults and Keychain items), its own data folder, and
/// no auto-updates.
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

    /// Builds without a feed (the dev variant: its feed is empty) never
    /// check for updates — a dev build must not replace itself with a
    /// release.
    public static let updatesEnabled: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false

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
              !container.isEmpty else { return nil }
        #if os(iOS)
        // iOS builds are always signed for it (no ad-hoc builds), and
        // can't read their entitlements.
        return container
        #else
        guard let task = SecTaskCreateFromSelf(nil),
              let entitled = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              entitled.contains(container) else { return nil }
        return container
        #endif
    }()

    /// This device's name: the Mac's, as in System Settings ▸ General ▸
    /// Sharing; on iOS, the model ("iPhone"), all apps may know.
    @MainActor
    static var computerName: String {
        #if os(macOS)
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "this Mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// Relay's own known_hosts: host keys trusted in Relay (the user's
    /// ~/.ssh/known_hosts is read but never written by the built-in client).
    static let knownHostsFile: URL = dataDirectory.appendingPathComponent("known_hosts")
}
