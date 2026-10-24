import Foundation
import Security

/// Host passwords: generic-password items in the login keychain, one per
/// host alias, scoped to this build's bundle ID (so the dev variant never
/// touches the real app's items). Never written to the host record.
enum SSHPasswordStore {
    private static let service = "\(AppVariant.bundleIdentifier) SSH password"

    private static func baseQuery(alias: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias,
        ]
    }

    static func load(alias: String) -> String? {
        var query = baseQuery(alias: alias)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    static func hasPassword(alias: String) -> Bool {
        var query = baseQuery(alias: alias)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ password: String, alias: String) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(
            baseQuery(alias: alias) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var query = baseQuery(alias: alias)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(alias: String) {
        SecItemDelete(baseQuery(alias: alias) as CFDictionary)
    }
}
