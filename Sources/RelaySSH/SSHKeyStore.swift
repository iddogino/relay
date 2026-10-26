import CryptoKit
import Foundation
@preconcurrency import NIOSSH
import Security

/// A key Relay signs with itself — what a host's "Relay key" sign-in
/// refers to (by `id`). The private half lives in the Keychain: synced
/// through iCloud Keychain, or as a Secure Enclave key that never leaves
/// the device it was made on.
public struct SSHKeyInfo: Codable, Sendable, Hashable, Identifiable {
    public enum Storage: String, Codable, Sendable {
        /// End-to-end encrypted iCloud Keychain item: every device signed
        /// into the account has it.
        case iCloudKeychain
        /// Made inside this device's Secure Enclave; can't be copied off it.
        case secureEnclave
    }

    public enum Origin: String, Codable, Sendable {
        /// Created by Relay (the shared synced key, or a device key).
        case generated
        /// Read from a key file the user already had.
        case imported
    }

    public let id: String
    public let storage: Storage
    public let origin: Origin
    /// `<algorithm> <base64 blob>`, as in authorized_keys.
    public let publicKey: String
    public var name: String
    /// The device that created (or imported) it.
    public let deviceName: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        storage: Storage,
        origin: Origin,
        publicKey: String,
        name: String,
        deviceName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.storage = storage
        self.origin = origin
        self.publicKey = publicKey
        self.name = name
        self.deviceName = deviceName
        self.createdAt = createdAt
    }

    /// The base64 key blob: what identifies the key in an authorized_keys
    /// file whatever its comment or options.
    public var publicKeyBlob: String {
        publicKey.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    /// The comment Relay writes after the key in authorized_keys, so the
    /// line says where it came from (and Relay can list its own keys).
    public var authorizedKeysComment: String {
        let label: String
        switch storage {
        case .iCloudKeychain: label = "iCloud Keychain"
        case .secureEnclave: label = deviceName
        }
        return "relay (\(label.filter { !$0.isNewline }))"
    }

    public var authorizedKeysLine: String { "\(publicKey) \(authorizedKeysComment)" }

    /// `SHA256:…`, as ssh-keygen -l prints it.
    public var fingerprint: String { KnownHosts.fingerprint(ofPublicKey: publicKey) ?? "" }
}

public enum SSHKeyStoreError: Error, Equatable, Sendable, LocalizedError {
    /// This build can't write iCloud Keychain items (it isn't signed with a
    /// Keychain entitlement).
    case syncUnavailable
    case secureEnclaveUnavailable
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .syncUnavailable:
            return "This build of Relay can't use iCloud Keychain."
        case .secureEnclaveUnavailable:
            return "This device has no Secure Enclave."
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain refused: \(message)"
        }
    }
}

/// Relay's own SSH keys.
public protocol SSHKeyStore: AnyObject, Sendable {
    /// Whether keys can be stored in iCloud Keychain in this build.
    var canSync: Bool { get }
    var canUseSecureEnclave: Bool { get }
    /// Every key this device can sign with (synced keys include ones made
    /// on other devices).
    func keys() -> [SSHKeyInfo]
    /// The private key for signing, or nil if it isn't on this device.
    func signingKey(id: String) -> NIOSSHPrivateKey?
    /// The account's shared synced key, created on first use.
    func syncedKey() throws -> SSHKeyInfo
    /// This device's Secure Enclave key, created on first use.
    func deviceKey() throws -> SSHKeyInfo
    /// Stores an existing key in iCloud Keychain (or returns the stored
    /// copy if it's already there).
    func importSynced(_ key: SSHPrivateKeyMaterial, name: String) throws -> SSHKeyInfo
    func delete(id: String) throws
}

extension SSHKeyStore {
    public func key(id: String) -> SSHKeyInfo? {
        keys().first { $0.id == id }
    }
}

/// Keys as Keychain generic-password items, one per key: account = key ID,
/// the `SSHKeyInfo` in the generic attribute, the private key (OpenSSH
/// format) or Secure Enclave key handle as the data.
///
/// With an access group (a build signed with a Keychain entitlement) items
/// go in the data protection keychain, synced keys with
/// `kSecAttrSynchronizable`. Without one (ad-hoc builds) only Secure
/// Enclave keys work, kept in the login keychain.
public final class KeychainSSHKeyStore: SSHKeyStore, @unchecked Sendable {
    public static let service = "Relay SSH key"

    private let accessGroup: String?
    private let service: String
    private let deviceName: String
    private let lock = NSLock()
    private var signingKeys: [String: NIOSSHPrivateKey] = [:]

    public init(accessGroup: String?, service: String = KeychainSSHKeyStore.service, deviceName: String) {
        self.accessGroup = accessGroup
        self.service = service
        self.deviceName = deviceName
    }

    public var canSync: Bool { accessGroup != nil }
    public var canUseSecureEnclave: Bool { SecureEnclave.isAvailable }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Queries match synced and device-only items alike (the login
    /// keychain has no synced items, and no such attribute).
    private func includeSynced(_ query: inout [String: Any]) {
        if accessGroup != nil { query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
    }

    public func keys() -> [SSHKeyInfo] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        includeSynced(&query)
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let data = item[kSecAttrGeneric as String] as? Data else { return nil }
            return try? JSONDecoder().decode(SSHKeyInfo.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func signingKey(id: String) -> NIOSSHPrivateKey? {
        if let cached = lock.withLock({ signingKeys[id] }) { return cached }
        guard let info = key(id: id), let data = secret(id: id) else { return nil }
        let key: NIOSSHPrivateKey?
        switch info.storage {
        case .iCloudKeychain:
            key = String(data: data, encoding: .utf8).flatMap { try? OpenSSHKeyFile.read($0, passphrase: nil).nioKey }
        case .secureEnclave:
            key = (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data))
                .map { NIOSSHPrivateKey(secureEnclaveP256Key: $0) }
        }
        if let key { lock.withLock { signingKeys[id] = key } }
        return key
    }

    private func secret(id: String) -> Data? {
        var query = baseQuery()
        query[kSecAttrAccount as String] = id
        includeSynced(&query)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func syncedKey() throws -> SSHKeyInfo {
        guard canSync else { throw SSHKeyStoreError.syncUnavailable }
        if let existing = keys().first(where: { $0.storage == .iCloudKeychain && $0.origin == .generated }) {
            return existing
        }
        let material = SSHPrivateKeyMaterial.generateEd25519()
        let info = SSHKeyInfo(
            storage: .iCloudKeychain, origin: .generated, publicKey: material.publicKey,
            name: "Relay key", deviceName: deviceName)
        try add(info, secret: Data(material.openSSHPrivateKey(comment: info.authorizedKeysComment).utf8))
        return info
    }

    public func deviceKey() throws -> SSHKeyInfo {
        guard canUseSecureEnclave else { throw SSHKeyStoreError.secureEnclaveUnavailable }
        if let existing = keys().first(where: { $0.storage == .secureEnclave }) {
            return existing
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        let nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: key)
        let info = SSHKeyInfo(
            storage: .secureEnclave, origin: .generated,
            publicKey: String(openSSHPublicKey: nioKey.publicKey),
            name: "Secure Enclave key", deviceName: deviceName)
        try add(info, secret: key.dataRepresentation)
        lock.withLock { signingKeys[info.id] = nioKey }
        return info
    }

    public func importSynced(_ key: SSHPrivateKeyMaterial, name: String) throws -> SSHKeyInfo {
        guard canSync else { throw SSHKeyStoreError.syncUnavailable }
        if let existing = keys().first(where: { $0.storage == .iCloudKeychain && $0.publicKey == key.publicKey }) {
            return existing
        }
        let info = SSHKeyInfo(
            storage: .iCloudKeychain, origin: .imported, publicKey: key.publicKey,
            name: name, deviceName: deviceName)
        try add(info, secret: Data(key.openSSHPrivateKey().utf8))
        return info
    }

    private func add(_ info: SSHKeyInfo, secret: Data) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = info.id
        query[kSecAttrLabel as String] = "\(info.name) (Relay SSH)"
        query[kSecAttrDescription as String] = "SSH private key"
        query[kSecAttrGeneric as String] = try JSONEncoder().encode(info)
        query[kSecValueData as String] = secret
        if accessGroup != nil {
            let synced = info.storage == .iCloudKeychain
            query[kSecAttrSynchronizable as String] = synced
            query[kSecAttrAccessible as String] = synced
                ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHKeyStoreError.keychain(status) }
    }

    public func delete(id: String) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = id
        includeSynced(&query)
        let status = SecItemDelete(query as CFDictionary)
        lock.withLock { signingKeys[id] = nil }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SSHKeyStoreError.keychain(status) }
    }
}

/// An in-memory store with the Keychain store's behavior, for tests (the
/// "Secure Enclave" keys are ordinary P-256 keys).
public final class InMemorySSHKeyStore: SSHKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(info: SSHKeyInfo, key: NIOSSHPrivateKey)] = []
    private let deviceName: String
    public let canSync: Bool
    public let canUseSecureEnclave: Bool

    public init(deviceName: String = "Test Mac", canSync: Bool = true, canUseSecureEnclave: Bool = true) {
        self.deviceName = deviceName
        self.canSync = canSync
        self.canUseSecureEnclave = canUseSecureEnclave
    }

    public func keys() -> [SSHKeyInfo] { lock.withLock { entries.map(\.info) } }

    public func signingKey(id: String) -> NIOSSHPrivateKey? {
        lock.withLock { entries.first { $0.info.id == id }?.key }
    }

    public func syncedKey() throws -> SSHKeyInfo {
        guard canSync else { throw SSHKeyStoreError.syncUnavailable }
        return try lock.withLock {
            if let existing = entries.first(where: { $0.info.storage == .iCloudKeychain && $0.info.origin == .generated }) {
                return existing.info
            }
            let material = SSHPrivateKeyMaterial.generateEd25519()
            let info = SSHKeyInfo(
                storage: .iCloudKeychain, origin: .generated, publicKey: material.publicKey,
                name: "Relay key", deviceName: deviceName)
            entries.append((info, material.nioKey))
            return info
        }
    }

    public func deviceKey() throws -> SSHKeyInfo {
        guard canUseSecureEnclave else { throw SSHKeyStoreError.secureEnclaveUnavailable }
        return lock.withLock {
            if let existing = entries.first(where: { $0.info.storage == .secureEnclave }) { return existing.info }
            let key = NIOSSHPrivateKey(p256Key: .init())
            let info = SSHKeyInfo(
                storage: .secureEnclave, origin: .generated, publicKey: String(openSSHPublicKey: key.publicKey),
                name: "Secure Enclave key", deviceName: deviceName)
            entries.append((info, key))
            return info
        }
    }

    public func importSynced(_ key: SSHPrivateKeyMaterial, name: String) throws -> SSHKeyInfo {
        guard canSync else { throw SSHKeyStoreError.syncUnavailable }
        return lock.withLock {
            if let existing = entries.first(where: { $0.info.publicKey == key.publicKey }) { return existing.info }
            let info = SSHKeyInfo(
                storage: .iCloudKeychain, origin: .imported, publicKey: key.publicKey, name: name, deviceName: deviceName)
            entries.append((info, key.nioKey))
            return info
        }
    }

    public func delete(id: String) throws {
        lock.withLock { entries.removeAll { $0.info.id == id } }
    }
}
