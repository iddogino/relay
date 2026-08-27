import Foundation

/// Identifies a runtime provider implementation (e.g. SSH+tmux).
public struct ProviderID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let sshTmux = ProviderID(rawValue: "ssh-tmux")
}

/// An opaque reference to a workspace owned by some provider.
/// For the SSH+tmux provider the opaque ID is the SSH alias, but nothing
/// above the provider layer may assume that.
public struct WorkspaceRef: Hashable, Codable, Sendable {
    public let provider: ProviderID
    public let opaqueID: String

    public init(provider: ProviderID, opaqueID: String) {
        self.provider = provider
        self.opaqueID = opaqueID
    }
}

public struct ProjectID: Hashable, Codable, Sendable {
    public let uuid: UUID
    public init(uuid: UUID = UUID()) { self.uuid = uuid }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.uuid = try container.decode(UUID.self)
    }
}

public struct SessionID: Hashable, Codable, Sendable {
    public let uuid: UUID
    public init(uuid: UUID = UUID()) { self.uuid = uuid }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.uuid = try container.decode(UUID.self)
    }
}
