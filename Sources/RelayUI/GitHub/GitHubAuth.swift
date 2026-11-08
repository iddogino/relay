import Foundation
import RelayCore

/// How the app is (or isn't) able to talk to the GitHub API. Shown in the
/// GitHub menu; gates PR status fetching.
enum GitHubConnection: Equatable {
    case checking
    case connected(login: String)
    case notConnected
    /// A credential exists but GitHub (or the network) rejected it — shown
    /// as an error state so the user knows the badge went dark and why.
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Where the device-flow login sheet is in its lifecycle.
enum GitHubLoginProgress: Equatable {
    case requesting
    case waiting(userCode: String, verificationURL: URL)
    case failed(String)
}

/// The device-flow token's home: a Keychain item named per variant ("Relay
/// GitHub", "Relay Dev GitHub") so the dev build never reads, overwrites
/// or signs out the real app's token. Synced through iCloud Keychain while
/// Sync with iCloud is on, so signing in (or out) on one device does on
/// all of them (see KeychainSecrets). Never lands on disk anywhere else.
enum GitHubTokenStore {
    static let secrets = KeychainSecrets(
        service: "\(AppVariant.dataDirectoryName) GitHub", accessGroup: AppVariant.keychainAccessGroup)
    static let account = "github.com"

    static func load() -> String? {
        secrets.load(account: account)
    }

    static func save(_ token: String) {
        secrets.save(token, account: account)
    }

    static func delete() {
        secrets.delete(account: account)
    }
}
