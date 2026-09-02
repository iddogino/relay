import Foundation
import Security
import RelayCore

/// How the app is (or isn't) able to talk to the GitHub API. Shown in the
/// GitHub menu; gates PR status fetching.
enum GitHubConnection: Equatable {
    case checking
    case connected(method: GitHubAuthMethod, login: String)
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

enum GitHubAuthMethod: Equatable {
    /// Borrowing the local `gh` CLI's token (re-read every check, so keyring
    /// rotation never bites).
    case cli
    /// Our own device-flow token, stored in the login keychain.
    case device
}

/// The device-flow token's home: a generic-password item in the user's
/// login keychain. Never lands on disk anywhere else.
enum GitHubTokenStore {
    private static let service = "Relay GitHub"
    private static let account = "github.com"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var query = baseQuery
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Locates and quietly interrogates a locally installed GitHub CLI. Used
/// only to borrow its token — every actual API call is ours.
enum GHCLI {
    /// Non-interactive apps inherit a bare PATH, so the usual install
    /// locations are probed directly.
    private static let candidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
        "/opt/local/bin/gh",
    ]

    static func executablePath() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The CLI's token for github.com, or nil when gh is missing or logged
    /// out (`gh auth token` exits non-zero).
    static func token() async -> String? {
        guard let gh = executablePath() else { return nil }
        guard let result = try? await SSHCommandRunner.runProcess(
            executable: gh,
            arguments: ["auth", "token", "--hostname", "github.com"],
            stdin: nil,
            timeout: .seconds(10)) else {
            return nil
        }
        guard result.exitCode == 0 else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
