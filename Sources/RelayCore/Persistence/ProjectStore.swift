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

/// The locally persisted app configuration. Hosts are rediscovered from SSH
/// config and sessions are reconciled from remote tmux; only app-owned
/// configuration lives here.
public struct PersistedState: Codable, Sendable {
    public var projects: [Project]
    public var tombstones: [CleanupTombstone]
    public var lastSelectedSessionID: SessionID?
    public var collapsedProjectIDs: Set<ProjectID>
    /// Remotes the user chose to hide from the sidebar.
    public var hiddenWorkspaces: Set<WorkspaceRef>

    public init(
        projects: [Project] = [],
        tombstones: [CleanupTombstone] = [],
        lastSelectedSessionID: SessionID? = nil,
        collapsedProjectIDs: Set<ProjectID> = [],
        hiddenWorkspaces: Set<WorkspaceRef> = []
    ) {
        self.projects = projects
        self.tombstones = tombstones
        self.lastSelectedSessionID = lastSelectedSessionID
        self.collapsedProjectIDs = collapsedProjectIDs
        self.hiddenWorkspaces = hiddenWorkspaces
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
