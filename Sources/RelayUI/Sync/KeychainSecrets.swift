import CryptoKit
import Foundation
import Security

/// Relay's secrets in the Keychain — the GitHub sign-in, host passwords:
/// generic-password items under one service, one per account.
///
/// In a build with a Keychain access group they live in the data
/// protection keychain: synced through iCloud Keychain (end-to-end
/// encrypted) while Sync with iCloud is on, on this device only while it's
/// off. A build without one (ad hoc) keeps them in the login keychain,
/// where builds before sync kept them; `moveFromLoginKeychain` brings
/// those over.
struct KeychainSecrets: Sendable {
    let service: String
    /// nil: the login keychain only.
    let accessGroup: String?

    enum Location: String, CaseIterable {
        /// iCloud Keychain.
        case synced
        /// The data protection keychain, this device only.
        case local
        /// The login keychain (builds before sync, ad-hoc builds).
        case login
    }

    /// Where saves go: follows Sync with iCloud.
    var active: Location {
        guard accessGroup != nil else { return .login }
        return AppModel.syncEnabledDefault ? .synced : .local
    }

    func load(account: String) -> String? {
        if let value = read(active, account: account) { return value }
        // Not moved over yet: the copy an earlier build saved.
        return loginKeychainInUse ? read(.login, account: account) : nil
    }

    func save(_ value: String, account: String) {
        write(value, to: active, account: account)
        if loginKeychainInUse { remove(.login, account: account) }
    }

    func delete(account: String) {
        remove(active, account: account)
        if loginKeychainInUse { remove(.login, account: account) }
    }

    /// Whether the login keychain may still hold this service's items:
    /// in builds that keep them there, and until they've been moved.
    private var loginKeychainInUse: Bool {
        active == .login || !UserDefaults.standard.bool(forKey: movedDefaultsKey)
    }

    private var movedDefaultsKey: String { "keychainMovedFromLogin.\(service)" }

    /// Deletes `account`'s item wherever it is (dev hooks: test cleanup).
    func deleteEverywhere(account: String) {
        for location in Location.allCases { remove(location, account: account) }
    }

    /// Which locations hold an item for `account`, each with a digest of
    /// its value to tell copies apart (for the dev hooks).
    func locations(account: String) -> [String: String] {
        var found: [String: String] = [:]
        for location in Location.allCases where location == .login || accessGroup != nil {
            guard let value = read(location, account: account) else { continue }
            found[location.rawValue] = SHA256.hash(data: Data(value.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        }
        return found
    }

    // MARK: Moving

    /// Moves what earlier builds saved in the login keychain to where saves
    /// go now. Run at launch, until it's done once. The login keychain
    /// copies are deleted too, but only the app that saved them may, and it
    /// counts as that app only at the same path (an update in place): a
    /// copy left behind is ignored from then on, rather than standing in
    /// for a secret since deleted (a GitHub sign-out).
    func moveFromLoginKeychain() {
        guard active != .login, loginKeychainInUse else { return }
        if move(from: .login, keepingSource: false) {
            UserDefaults.standard.set(true, forKey: movedDefaultsKey)
        }
    }

    /// Sync with iCloud was turned on or off. On: this device's items join
    /// iCloud Keychain. Off: synced items are copied to this device, and
    /// stay in iCloud Keychain for the user's other devices. Where both
    /// places have an item, the newer one wins.
    func syncChanged(enabled: Bool) {
        guard accessGroup != nil else { return }
        if enabled {
            move(from: .local, keepingSource: false)
        } else {
            move(from: .synced, keepingSource: true)
        }
    }

    /// Returns whether every item made it over.
    @discardableResult
    private func move(from source: Location, keepingSource: Bool) -> Bool {
        let target = active
        guard source != target else { return true }
        var complete = true
        for (account, modified) in accountsAndDates(source) {
            guard let value = read(source, account: account) else {
                complete = false
                continue
            }
            let targetModified = accountsAndDates(target, account: account).first?.modified
            if targetModified == nil || (modified ?? .distantPast) > (targetModified ?? .distantPast) {
                guard write(value, to: target, account: account) else {
                    complete = false
                    continue
                }
            }
            if !keepingSource { remove(source, account: account) }
        }
        return complete
    }

    // MARK: Keychain

    private func query(_ location: Location, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        switch location {
        case .login:
            // Explicitly: left out, a query also matches the data
            // protection keychain's device-only items.
            query[kSecUseDataProtectionKeychain as String] = false
        case .synced, .local:
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecAttrSynchronizable as String] = location == .synced
        }
        return query
    }

    private func read(_ location: Location, account: String) -> String? {
        guard location == .login || accessGroup != nil else { return nil }
        var query = query(location, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    private func write(_ value: String, to location: Location, account: String) -> Bool {
        let data = Data(value.utf8)
        let base = query(location, account: account)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            // Readable while the screen is locked (sessions reconnect
            // then), as login keychain items are.
            switch location {
            case .synced: add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            case .local: add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .login: break
            }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            ghosttyLogger.error("keychain: couldn't save \(service, privacy: .public) (\(location.rawValue, privacy: .public)): \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    @discardableResult
    private func remove(_ location: Location, account: String) -> Bool {
        guard location == .login || accessGroup != nil else { return true }
        let status = SecItemDelete(query(location, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            ghosttyLogger.error("keychain: couldn't delete \(service, privacy: .public) (\(location.rawValue, privacy: .public)): \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// Accounts with an item in `location` (just `account`'s, if given),
    /// with when each was last changed.
    private func accountsAndDates(_ location: Location, account: String? = nil) -> [(account: String, modified: Date?)] {
        guard location == .login || accessGroup != nil else { return [] }
        var query = query(location, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let found = items as? [[String: Any]] else { return [] }
        return found.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            return (account, attributes[kSecAttrModificationDate as String] as? Date)
        }
    }
}
