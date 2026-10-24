import Foundation

/// Which build this is. The dev variant ("Relay Dev", built with
/// `RELAY_VARIANT=dev Scripts/build-app.sh`) installs alongside the real
/// app: its own bundle ID (so its own UserDefaults and Keychain items), its
/// own data folder, and no auto-updates.
enum AppVariant {
    /// Folder under Application Support holding state.json and generated
    /// config files.
    static let dataDirectoryName: String =
        Bundle.main.object(forInfoDictionaryKey: "RelayDataDirectory") as? String ?? "Relay"

    static let dataDirectory: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataDirectoryName, isDirectory: true)

    /// Builds without a feed (the dev variant) never check for updates —
    /// a dev build must not replace itself with a release.
    static let updatesEnabled: Bool =
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    static let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.iddogino.Relay"
}
