import Foundation

/// A folder on a workspace that the user works in. Configured locally.
public struct Project: Identifiable, Codable, Sendable, Hashable {
    public let id: ProjectID
    public var name: String
    public var workspace: WorkspaceRef
    /// The path exactly as the user typed it (may contain `~`).
    public var pathInput: String
    /// The canonical remote path returned by validation.
    public var resolvedPath: String
    /// Optional shell command run when a new session is created.
    public var launchCommand: String?
    /// Optional shell command run when a session is archived.
    public var shutdownCommand: String?
    /// Provider-owned opaque values captured during validation
    /// (e.g. resolved tool paths). Never interpreted above the provider.
    public var runtimeMetadata: [String: String]

    public init(
        id: ProjectID = ProjectID(),
        name: String,
        workspace: WorkspaceRef,
        pathInput: String,
        resolvedPath: String,
        launchCommand: String? = nil,
        shutdownCommand: String? = nil,
        runtimeMetadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.workspace = workspace
        self.pathInput = pathInput
        self.resolvedPath = resolvedPath
        self.launchCommand = launchCommand
        self.shutdownCommand = shutdownCommand
        self.runtimeMetadata = runtimeMetadata
    }
}

/// Result of validating a project's path and prerequisites on its workspace.
public struct ProjectValidation: Sendable {
    public let resolvedPath: String
    public let runtimeMetadata: [String: String]
    /// Human-readable details, e.g. detected tmux version.
    public let notes: [String]

    public init(resolvedPath: String, runtimeMetadata: [String: String] = [:], notes: [String] = []) {
        self.resolvedPath = resolvedPath
        self.runtimeMetadata = runtimeMetadata
        self.notes = notes
    }
}
