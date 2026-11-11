import Foundation

/// A session that was archived but whose cleanup hook failed. Kept so the
/// user can retry or dismiss the cleanup.
public struct CleanupTombstone: Codable, Sendable, Identifiable, Hashable {
    public var id: SessionID { session.id }
    public let session: RemoteSession
    public let projectID: ProjectID
    public var failureMessage: String
    public let failedAt: Date

    public init(session: RemoteSession, projectID: ProjectID, failureMessage: String, failedAt: Date = Date()) {
        self.session = session
        self.projectID = projectID
        self.failureMessage = failureMessage
        self.failedAt = failedAt
    }
}

/// The locally persisted app configuration. Sessions are reconciled from
/// remote tmux; only app-owned configuration lives here.
public struct PersistedState: Codable, Sendable {
    public var projects: [Project]
    public var tombstones: [CleanupTombstone]
    public var lastSelectedSessionID: SessionID?
    public var collapsedProjectIDs: Set<ProjectID>
    /// Remotes the user chose to hide from the sidebar.
    public var hiddenWorkspaces: Set<WorkspaceRef>
    /// The user's drag-to-reorder session arrangement (see SessionOrdering).
    public var sessionOrder: [SessionID]
    /// Relay's host list. nil only in state written before Relay owned its
    /// hosts (they came from `~/.ssh/config`) — the cue to migrate.
    public var hosts: [SSHHost]?
    /// Host records in the file that this build can't read (written by a
    /// newer build, or damaged), exactly as found. They're written back
    /// untouched and are never taken for hosts the user removed: sync
    /// would otherwise delete them on every device.
    public var unreadableHosts: [JSONValue]
    /// Where the hosts and projects stand with iCloud (see SyncState).
    /// Saved in the same file so the two can never disagree.
    public var sync: SyncState?

    public init(
        projects: [Project] = [],
        tombstones: [CleanupTombstone] = [],
        lastSelectedSessionID: SessionID? = nil,
        collapsedProjectIDs: Set<ProjectID> = [],
        hiddenWorkspaces: Set<WorkspaceRef> = [],
        sessionOrder: [SessionID] = [],
        hosts: [SSHHost]? = nil,
        unreadableHosts: [JSONValue] = [],
        sync: SyncState? = nil
    ) {
        self.projects = projects
        self.tombstones = tombstones
        self.lastSelectedSessionID = lastSelectedSessionID
        self.collapsedProjectIDs = collapsedProjectIDs
        self.hiddenWorkspaces = hiddenWorkspaces
        self.sessionOrder = sessionOrder
        self.hosts = hosts
        self.unreadableHosts = unreadableHosts
        self.sync = sync
    }

    /// The aliases of the hosts this build couldn't read, where they can
    /// still be made out.
    public var unreadableHostAliases: [String] {
        unreadableHosts.compactMap { record in
            if case .object(let fields) = record, case .string(let alias)? = fields["alias"] { return alias }
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case projects, tombstones, lastSelectedSessionID, collapsedProjectIDs, hiddenWorkspaces, sessionOrder, hosts, sync
    }

    // Every field decodes with a default so state files written by older
    // builds (or with fields yet to exist) load instead of tripping the
    // corrupt-state path.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        self.tombstones = try container.decodeIfPresent([CleanupTombstone].self, forKey: .tombstones) ?? []
        self.lastSelectedSessionID = try container.decodeIfPresent(SessionID.self, forKey: .lastSelectedSessionID)
        self.collapsedProjectIDs = try container.decodeIfPresent(Set<ProjectID>.self, forKey: .collapsedProjectIDs) ?? []
        self.hiddenWorkspaces = try container.decodeIfPresent(Set<WorkspaceRef>.self, forKey: .hiddenWorkspaces) ?? []
        self.sessionOrder = try container.decodeIfPresent([SessionID].self, forKey: .sessionOrder) ?? []
        // Lossy per record: one unreadable host must never send the whole
        // state file down the corrupt-state path. What can't be read is
        // kept as it is (unreadableHosts).
        let records = try container.decodeIfPresent([HostRecord].self, forKey: .hosts)
        self.hosts = records?.compactMap(\.host)
        self.unreadableHosts = records?.compactMap { $0.host == nil ? $0.raw : nil } ?? []
        // Unreadable sync state starts over (iCloud's copies then win)
        // rather than losing the hosts and projects beside it.
        self.sync = try? container.decodeIfPresent(SyncState.self, forKey: .sync)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(tombstones, forKey: .tombstones)
        try container.encodeIfPresent(lastSelectedSessionID, forKey: .lastSelectedSessionID)
        try container.encode(collapsedProjectIDs, forKey: .collapsedProjectIDs)
        try container.encode(hiddenWorkspaces, forKey: .hiddenWorkspaces)
        try container.encode(sessionOrder, forKey: .sessionOrder)
        if hosts != nil || !unreadableHosts.isEmpty {
            var list = container.nestedUnkeyedContainer(forKey: .hosts)
            for host in hosts ?? [] { try list.encode(host) }
            for record in unreadableHosts { try list.encode(record) }
        }
        try container.encodeIfPresent(sync, forKey: .sync)
    }

    private struct HostRecord: Decodable {
        let host: SSHHost?
        let raw: JSONValue
        init(from decoder: Decoder) throws {
            host = try? SSHHost(from: decoder)
            raw = (try? JSONValue(from: decoder)) ?? .null
        }
    }
}

/// Any JSON, kept as it was read.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: Key.self) {
            var fields: [String: JSONValue] = [:]
            for key in keyed.allKeys { fields[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key) }
            self = .object(fields)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(JSONValue.self)) }
            self = .array(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        case .bool(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .integer(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .number(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .string(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .array(let items):
            var unkeyed = encoder.unkeyedContainer()
            for item in items { try unkeyed.encode(item) }
        case .object(let fields):
            var keyed = encoder.container(keyedBy: Key.self)
            for (name, value) in fields { try keyed.encode(value, forKey: Key(name)) }
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

public enum ProjectStoreError: Error, Sendable {
    case corruptState(backupPath: String)
}

/// Atomic JSON persistence under Application Support.
public actor ProjectStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base.appendingPathComponent("Relay/state.json")
        }
    }

    /// Loads persisted state. A missing file returns empty state. A corrupt
    /// file is moved aside (never destroys remote state or triggers remote
    /// operations) and reported.
    public func load() throws -> PersistedState {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            return PersistedState()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PersistedState.self, from: data)
        } catch {
            let backupURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            throw ProjectStoreError.corruptState(backupPath: backupURL.path)
        }
    }

    public func save(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
