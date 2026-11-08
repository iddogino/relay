import Foundation

/// Host passwords: Keychain items, one per host alias, scoped to this
/// build's bundle ID (so the dev variant never touches the real app's
/// items). Synced through iCloud Keychain while Sync with iCloud is on,
/// like the hosts themselves (see KeychainSecrets). Never written to the
/// host record.
enum SSHPasswordStore {
    static let secrets = KeychainSecrets(
        service: "\(AppVariant.bundleIdentifier) SSH password", accessGroup: AppVariant.keychainAccessGroup)

    static func load(alias: String) -> String? {
        secrets.load(account: alias)
    }

    static func hasPassword(alias: String) -> Bool {
        load(alias: alias) != nil
    }

    static func save(_ password: String, alias: String) {
        secrets.save(password, account: alias)
    }

    static func delete(alias: String) {
        secrets.delete(account: alias)
    }
}
