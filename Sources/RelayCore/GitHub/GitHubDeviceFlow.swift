import Foundation

/// GitHub OAuth device flow: the no-CLI login path. `begin` yields a short
/// user code the person types at github.com/login/device; the caller then
/// `poll`s until GitHub hands back a token. Needs only a public OAuth app
/// client ID (device flow enabled) — no client secret, no callback URL.
public struct GitHubDeviceFlow: Sendable {
    public typealias Transport = GitHubAPIClient.Transport

    public struct Authorization: Sendable, Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURL: URL
        /// Minimum seconds between polls (GitHub enforces this).
        public var interval: Int
        public var expiresIn: Int
    }

    public enum PollOutcome: Sendable, Equatable {
        case authorized(token: String)
        /// Not approved yet (or we polled too fast) — poll again after
        /// `retryAfter` seconds.
        case pending(retryAfter: Int)
        case denied
        case expired
    }

    public enum FlowError: Error, Equatable {
        case badResponse(String)
    }

    private let transport: Transport

    public init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    public func begin(clientID: String, scope: String = "repo") async throws -> Authorization {
        let data = try await post(
            "https://github.com/login/device/code",
            form: ["client_id": clientID, "scope": scope])
        return try Self.parseAuthorization(data)
    }

    public func poll(
        clientID: String,
        deviceCode: String,
        currentInterval: Int
    ) async throws -> PollOutcome {
        let data = try await post(
            "https://github.com/login/oauth/access_token",
            form: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
        return try Self.parsePoll(data, currentInterval: currentInterval)
    }

    // MARK: Parsing (errors arrive as 200s with an "error" field)

    struct WireResponse: Decodable {
        let deviceCode: String?
        let userCode: String?
        let verificationUri: String?
        let expiresIn: Int?
        let interval: Int?
        let accessToken: String?
        let error: String?
        let errorDescription: String?
    }

    static func parseAuthorization(_ data: Data) throws -> Authorization {
        let wire = try decode(data)
        if let error = wire.error {
            throw FlowError.badResponse(wire.errorDescription ?? error)
        }
        guard let deviceCode = wire.deviceCode,
              let userCode = wire.userCode,
              let uri = wire.verificationUri,
              let url = URL(string: uri) else {
            throw FlowError.badResponse("Malformed device code response.")
        }
        return Authorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: url,
            interval: max(wire.interval ?? 5, 1),
            expiresIn: wire.expiresIn ?? 900)
    }

    static func parsePoll(_ data: Data, currentInterval: Int) throws -> PollOutcome {
        let wire = try decode(data)
        if let token = wire.accessToken {
            return .authorized(token: token)
        }
        switch wire.error {
        case "authorization_pending":
            return .pending(retryAfter: currentInterval)
        case "slow_down":
            return .pending(retryAfter: wire.interval ?? currentInterval + 5)
        case "access_denied":
            return .denied
        case "expired_token":
            return .expired
        default:
            throw FlowError.badResponse(wire.errorDescription ?? wire.error ?? "Malformed poll response.")
        }
    }

    private static func decode(_ data: Data) throws -> WireResponse {
        do {
            return try GitHubAPIClient.decoder().decode(WireResponse.self, from: data)
        } catch {
            throw FlowError.badResponse("Malformed response from GitHub.")
        }
    }

    private func post(_ urlString: String, form: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw FlowError.badResponse("Bad URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form
            .map { key, value in
                let safe = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(safe)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FlowError.badResponse("GitHub returned HTTP \(code).")
        }
        return data
    }
}
