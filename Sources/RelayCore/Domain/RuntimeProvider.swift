import Foundation

/// A workspace a provider can run sessions in. For SSH+tmux, one per SSH alias.
public struct WorkspaceDescriptor: Identifiable, Sendable, Hashable {
    public let id: WorkspaceRef
    public let displayName: String
    public let providerID: ProviderID

    public init(id: WorkspaceRef, displayName: String, providerID: ProviderID) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
    }
}

public struct RuntimeCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let persistentSessions = RuntimeCapabilities(rawValue: 1 << 0)
    public static let staticWorkspaces = RuntimeCapabilities(rawValue: 1 << 1)

    // Reserved for future providers. No v1 UI.
    public static let provisionWorkspaces = RuntimeCapabilities(rawValue: 1 << 2)
    public static let destroyWorkspaces = RuntimeCapabilities(rawValue: 1 << 3)
    public static let suspendResume = RuntimeCapabilities(rawValue: 1 << 4)
    public static let snapshots = RuntimeCapabilities(rawValue: 1 << 5)
}

/// Backend-produced description of how to attach a terminal to a session.
/// For v1 this is a local child-process launch spec.
public struct TerminalLaunchSpec: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// The boundary between the UI/domain layer and a concrete session backend.
/// Views and view models depend only on this protocol; SSH/tmux knowledge
/// lives entirely inside `SSHTmuxRuntimeProvider`.
public protocol RuntimeProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: RuntimeCapabilities { get }

    func discoverWorkspaces() async throws -> [WorkspaceDescriptor]
    func validate(project: Project) async throws -> ProjectValidation

    func listSessions(for project: Project) async throws -> [RemoteSession]
    func createSession(for project: Project, request: NewSessionRequest) async throws -> RemoteSession

    func makeTerminalLaunch(for session: RemoteSession, project: Project) async throws -> TerminalLaunchSpec

    func sessionExists(_ session: RemoteSession, project: Project) async throws -> Bool

    /// Normal finalization path: terminates the runtime session, then runs the
    /// project's shutdown hook (if configured). Throws `.cleanupFailed` if the
    /// hook fails; the runtime session is still terminated in that case and
    /// calling this again retries only the remaining work.
    func archiveSession(_ session: RemoteSession, project: Project) async throws

    /// Force/destructive escape hatch. Never runs the shutdown hook.
    func destroySession(_ session: RemoteSession, project: Project) async throws
}

public enum RuntimeProviderError: Error, Sendable, LocalizedError, Equatable {
    case invalidInput(String)
    case workspaceUnreachable(workspace: String, detail: String)
    case authenticationRequired(workspace: String)
    case prerequisiteMissing(workspace: String, what: String, remedy: String)
    case pathInvalid(workspace: String, path: String)
    case sessionNotFound(workspace: String)
    case operationFailed(String)
    case cleanupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .workspaceUnreachable(let workspace, let detail):
            return "Can't reach \(workspace).\n\(detail)"
        case .authenticationRequired(let workspace):
            return "SSH needs interactive authentication or host verification. Verify `ssh \(workspace)` works in Terminal, then retry."
        case .prerequisiteMissing(let workspace, let what, let remedy):
            return "\(what) is not available on \(workspace). \(remedy)"
        case .pathInvalid(let workspace, let path):
            return "\(path) does not exist (or is not a directory) on \(workspace)."
        case .sessionNotFound(let workspace):
            return "This session no longer exists on \(workspace)."
        case .operationFailed(let message):
            return message
        case .cleanupFailed(let message):
            return "Cleanup command failed.\n\(message)"
        }
    }
}
