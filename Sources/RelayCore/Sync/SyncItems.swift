import CryptoKit
import Foundation

/// A host as it syncs: Relay's record plus the host keys this device
/// trusts for it, so another device can connect without being asked to
/// trust the host again.
public struct SyncedHost: Codable, Sendable, Hashable {
    public var host: SSHHost
    /// `<type> <base64>`, sorted (KnownHosts.trustedKeys).
    public var trustedHostKeys: [String]

    public init(host: SSHHost, trustedHostKeys: [String] = []) {
        self.host = host
        self.trustedHostKeys = trustedHostKeys
    }

    private enum Keys: String, CodingKey {
        case trustedHostKeys
    }

    // Flat (the host's own keys beside `trustedHostKeys`): what a build
    // doesn't know is kept at the top level (SyncPayload), so a field a
    // newer build adds to hosts survives an older build's edit.
    public func encode(to encoder: Encoder) throws {
        try host.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(trustedHostKeys, forKey: .trustedHostKeys)
    }

    public init(from decoder: Decoder) throws {
        host = try SSHHost(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        trustedHostKeys = try container.decodeIfPresent([String].self, forKey: .trustedHostKeys) ?? []
    }
}

/// The sidebar's project order.
public struct SyncedProjectOrder: Codable, Sendable, Hashable {
    public var projects: [ProjectID]

    public init(projects: [ProjectID]) {
        self.projects = projects
    }

    /// `projects` in this order. Ones it doesn't name (added here since)
    /// keep their relative order, after the rest.
    public func arrange(_ projects: [Project]) -> [Project] {
        var rank: [ProjectID: Int] = [:]
        for (index, id) in self.projects.enumerated() where rank[id] == nil { rank[id] = index }
        return projects.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? Int.max
                let rb = rank[b.element.id] ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }
}

/// What kind of thing a synced record holds — its CloudKit record type.
public enum SyncKind: String, Codable, Sendable, CaseIterable {
    case host = "Host"
    case project = "Project"
    case projectOrder = "ProjectOrder"
}

/// One synced thing: a host, a project, or the project order. Each is
/// one record, named after its identity, so two devices that make the
/// same host (same alias) or keep the same project (same ID) converge on
/// one record.
public enum SyncItem: Sendable, Hashable {
    case host(SyncedHost)
    case project(Project)
    case projectOrder(SyncedProjectOrder)

    public var kind: SyncKind {
        switch self {
        case .host: return .host
        case .project: return .project
        case .projectOrder: return .projectOrder
        }
    }

    public var recordName: String {
        switch self {
        case .host(let synced): return Self.recordName(hostAlias: synced.host.alias)
        case .project(let project): return Self.recordName(project: project.id)
        case .projectOrder: return Self.projectOrderRecordName
        }
    }

    /// Record names are visible to the server, unlike record contents
    /// (encrypted), so a host's is a digest of its alias.
    public static func recordName(hostAlias alias: String) -> String {
        let digest = SHA256.hash(data: Data("host:\(alias)".utf8))
        return "host-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func recordName(project id: ProjectID) -> String {
        "project-" + id.uuid.uuidString.lowercased()
    }

    public static let projectOrderRecordName = "projectOrder"
}

/// How an item travels: an envelope (when it was made, whether it's a
/// deletion) around the item's JSON. The whole envelope is one encrypted
/// record field, so iCloud stores it end-to-end encrypted.
///
/// Items compare by their canonical JSON (sorted keys). Keys in a
/// received item that this build doesn't decode are kept separately
/// (`extra`) and sent back with this device's edits, so a field added by
/// a newer build isn't lost when an older one edits the item.
public enum SyncPayload {
    /// The envelope format.
    static let version = 1

    public struct Parsed: Sendable, Equatable {
        public var modifiedAt: Date
        /// The item's canonical JSON, nil for a deletion.
        public var payload: Data?
        /// Top-level item keys this build doesn't decode (a JSON object).
        public var extra: Data?
    }

    public enum Failure: Error, Equatable {
        case malformed
        /// The item doesn't belong under the record's name.
        case misnamed
        case invalid(String)
    }

    public static func canonical(_ item: SyncItem) throws -> Data {
        switch item {
        case .host(let synced): return try encoder.encode(synced)
        case .project(let project): return try encoder.encode(project)
        case .projectOrder(let order): return try encoder.encode(order)
        }
    }

    public static func item(kind: SyncKind, payload: Data) throws -> SyncItem {
        switch kind {
        case .host: return .host(try decoder.decode(SyncedHost.self, from: payload))
        case .project: return .project(try decoder.decode(Project.self, from: payload))
        case .projectOrder: return .projectOrder(try decoder.decode(SyncedProjectOrder.self, from: payload))
        }
    }

    public static func envelope(payload: Data?, extra: Data?, modifiedAt: Date) -> Data {
        var object: [String: Any] = [
            "v": version,
            "modifiedAt": modifiedAt.timeIntervalSinceReferenceDate,
            "deleted": payload == nil,
        ]
        if let payload, var item = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            if let extra, let unknown = try? JSONSerialization.jsonObject(with: extra) as? [String: Any] {
                item.merge(unknown) { known, _ in known }
            }
            object["item"] = item
        }
        // Only property-list-safe values above: serialization can't fail.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Reads an envelope from a record named `recordName`, checking the
    /// item belongs there and is one Relay can use.
    public static func parse(_ envelope: Data, kind: SyncKind, recordName: String) throws -> Parsed {
        guard let object = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let modified = (object["modifiedAt"] as? NSNumber)?.doubleValue else {
            throw Failure.malformed
        }
        let modifiedAt = Date(timeIntervalSinceReferenceDate: modified)
        if (object["deleted"] as? Bool) == true {
            return Parsed(modifiedAt: modifiedAt, payload: nil, extra: nil)
        }
        guard let raw = object["item"] as? [String: Any],
              let rawData = try? JSONSerialization.data(withJSONObject: raw) else {
            throw Failure.malformed
        }
        let item: SyncItem
        do {
            item = try self.item(kind: kind, payload: rawData)
        } catch {
            throw Failure.malformed
        }
        guard item.recordName == recordName else { throw Failure.misnamed }
        if case .host(let synced) = item {
            do {
                try synced.host.validate()
            } catch {
                throw Failure.invalid(error.localizedDescription)
            }
        }
        let payload = try canonical(item)
        let known = Set(((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]).keys)
        let unknown = raw.filter { !known.contains($0.key) }
        let extra = unknown.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
        return Parsed(modifiedAt: modifiedAt, payload: payload, extra: extra)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
