import Foundation
import RelaySSH

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
    /// The provider can copy local files into the session's workspace
    /// (drag & drop upload).
    public static let fileUpload = RuntimeCapabilities(rawValue: 1 << 6)

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
    /// Set when the terminal should run over Relay's built-in SSH client
    /// instead of `executable` (which then remains the description of the
    /// equivalent system-ssh launch).
    public let builtIn: BuiltInTerminal?

    public init(executable: URL, arguments: [String], environment: [String: String], builtIn: BuiltInTerminal? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.builtIn = builtIn
    }
}

/// A terminal session over the built-in SSH client: where to connect and
/// what to run there — the same remote command line the system ssh would
/// send.
public struct BuiltInTerminal: Sendable {
    public let target: SSHTarget
    public let command: String
    public let environment: [(String, String)]
    public let pool: SSHConnectionPool
    /// Call when the session couldn't be opened: the host then uses the
    /// system ssh for a while, so the next attach doesn't fail the same way.
    public let reportOpenFailure: @Sendable (Error) -> Void

    public init(
        target: SSHTarget,
        command: String,
        environment: [(String, String)],
        pool: SSHConnectionPool,
        reportOpenFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.target = target
        self.command = command
        self.environment = environment
        self.pool = pool
        self.reportOpenFailure = reportOpenFailure
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

    /// Names of the child directories of `pathInput` on `workspace`, for
    /// folder-field autocomplete while a project is being configured (no
    /// Project exists yet). Optional: the default returns no suggestions —
    /// autocomplete is an enhancement, never a requirement.
    func listChildDirectories(workspace: WorkspaceRef, pathInput: String) async throws -> [String]

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

    /// Rewrites the session's display name in provider metadata; the
    /// backend identifier is untouched. Optional: the default refuses.
    func renameSession(_ session: RemoteSession, to name: String, project: Project) async throws

    /// Copies local files/directories into a fresh scratch location on the
    /// session's machine and returns the resulting remote paths, in input
    /// order. Only meaningful when `capabilities` contains `.fileUpload`.
    /// Implementations must be cancellation-aware (a cancelled upload throws
    /// `CancellationError` and leaves no half-referenced paths behind).
    /// `progress`, when the provider can measure it, is called from an
    /// arbitrary thread as the transfer advances.
    func uploadFiles(
        localPaths: [String],
        for session: RemoteSession,
        project: Project,
        progress: (@Sendable (UploadProgress) -> Void)?
    ) async throws -> [String]

    /// Git state of the session's working directory (diff counts, branch,
    /// linked PR), or nil when the session isn't in a git context. Optional:
    /// the default implementation reports no git context.
    func gitState(for session: RemoteSession, project: Project) async throws -> SessionGitState?

    /// The session's full diff against the same base `gitState` uses, or
    /// nil when the session isn't in a git context.
    func gitDiff(for session: RemoteSession, project: Project) async throws -> SessionGitDiff?

    /// Working-tree content of one repo-relative file from the session's
    /// repository, for the diff tray's full-file mode. nil when the file is
    /// missing, unreadable, over the provider's size cap, or the provider
    /// doesn't support the fetch (the default) — callers fall back to the
    /// hunks-only view.
    func gitFileContent(for session: RemoteSession, project: Project, repoRelativePath: String) async throws -> String?

    /// Copies one file from the session's machine into a disposable local
    /// location (the OS temp area, reclaimed automatically) and returns its
    /// URL, for previewing a file link clicked in the terminal. `linkPath`
    /// is the path as the terminal printed it — absolute, `~/`, or relative
    /// to the session's current directory.
    func fetchPreviewFile(linkPath: String, for session: RemoteSession, project: Project) async throws -> URL

    /// Samples the workspace machine's general load (load average, memory,
    /// CPU, …) repeatedly, calling `onSample` from an arbitrary thread for
    /// each sample, until the provider's sampling run ends (returns), it
    /// fails (throws), or the task is cancelled (throws CancellationError).
    /// `detailed` asks for a faster cadence plus the extra metrics (busiest
    /// processes, GPUs). Optional and best-effort: the default throws.
    func monitorMachineLoad(
        workspace: WorkspaceRef,
        detailed: Bool,
        onSample: @escaping @Sendable (MachineLoadSample) -> Void
    ) async throws

    /// Whether each coding agent's CLI exists on the workspace machine and
    /// has Relay's global status reporter installed. Also refreshes stale
    /// reporter files. Optional: the default reports nothing.
    func probeAgentReporters(workspace: WorkspaceRef) async throws -> [CodingAgent: AgentReporterStatus]

    /// Installs Relay's status reporter into `agent`'s global configuration
    /// on the workspace machine, so every session of it reports. Optional:
    /// the default throws.
    func installGlobalAgentReporter(workspace: WorkspaceRef, agent: CodingAgent) async throws

    /// Streams every session's agent status on the workspace machine,
    /// calling `onSnapshot` (arbitrary thread) with the full set whenever
    /// it changes and periodically as a heartbeat, until the run ends
    /// (returns), fails (throws), or the task is cancelled. Optional: the
    /// default throws.
    func monitorAgentStatus(
        workspace: WorkspaceRef,
        onSnapshot: @escaping @Sendable ([AgentStatusReport]) -> Void
    ) async throws
}

/// A parsed session diff, ready to render.
public struct SessionGitDiff: Sendable, Equatable {
    public var branch: String
    public var baseRef: String?
    public var files: [DiffFile]
    /// True when the provider capped a very large diff body.
    public var truncated: Bool

    public init(branch: String, baseRef: String? = nil, files: [DiffFile] = [], truncated: Bool = false) {
        self.branch = branch
        self.baseRef = baseRef
        self.files = files
        self.truncated = truncated
    }
}

extension RuntimeProvider {
    public func listChildDirectories(workspace: WorkspaceRef, pathInput: String) async throws -> [String] { [] }

    public func uploadFiles(
        localPaths: [String],
        for session: RemoteSession,
        project: Project,
        progress: (@Sendable (UploadProgress) -> Void)?
    ) async throws -> [String] {
        throw RuntimeProviderError.operationFailed("This provider does not support file uploads.")
    }

    public func uploadFiles(localPaths: [String], for session: RemoteSession, project: Project) async throws -> [String] {
        try await uploadFiles(localPaths: localPaths, for: session, project: project, progress: nil)
    }

    public func renameSession(_ session: RemoteSession, to name: String, project: Project) async throws {
        throw RuntimeProviderError.operationFailed("This provider can't rename sessions.")
    }

    public func gitState(for session: RemoteSession, project: Project) async throws -> SessionGitState? { nil }

    public func gitDiff(for session: RemoteSession, project: Project) async throws -> SessionGitDiff? { nil }

    public func gitFileContent(for session: RemoteSession, project: Project, repoRelativePath: String) async throws -> String? { nil }

    public func fetchPreviewFile(linkPath: String, for session: RemoteSession, project: Project) async throws -> URL {
        throw RuntimeProviderError.operationFailed("This provider can't preview remote files.")
    }

    public func monitorMachineLoad(
        workspace: WorkspaceRef,
        detailed: Bool,
        onSample: @escaping @Sendable (MachineLoadSample) -> Void
    ) async throws {
        throw RuntimeProviderError.operationFailed("This provider can't report machine load.")
    }

    public func probeAgentReporters(workspace: WorkspaceRef) async throws -> [CodingAgent: AgentReporterStatus] { [:] }

    public func installGlobalAgentReporter(workspace: WorkspaceRef, agent: CodingAgent) async throws {
        throw RuntimeProviderError.operationFailed("This provider can't install agent status reporting.")
    }

    public func monitorAgentStatus(
        workspace: WorkspaceRef,
        onSnapshot: @escaping @Sendable ([AgentStatusReport]) -> Void
    ) async throws {
        throw RuntimeProviderError.operationFailed("This provider can't report agent status.")
    }
}

public enum RuntimeProviderError: Error, Sendable, LocalizedError, Equatable {
    case invalidInput(String)
    case workspaceUnreachable(workspace: String, detail: String)
    case authenticationRequired(workspace: String)
    /// The host must be set up again in Relay (Settings ▸ Hosts) — its
    /// Relay key isn't on this device, or its identity isn't trusted.
    case hostNeedsSetup(workspace: String, reason: String)
    case prerequisiteMissing(workspace: String, what: String, remedy: String)
    case pathInvalid(workspace: String, path: String)
    case sessionNotFound(workspace: String)
    case operationFailed(String)
    case cleanupFailed(String)
    case uploadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .workspaceUnreachable(let workspace, let detail):
            return "Can't reach \(workspace).\n\(detail)"
        case .authenticationRequired(let workspace):
            return "SSH needs interactive authentication or host verification. Verify `ssh \(workspace)` works in Terminal, then retry."
        case .hostNeedsSetup(let workspace, let reason):
            return "\(workspace) needs connecting on this device. \(reason) Set it up in Settings ▸ Hosts."
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
        case .uploadFailed(let message):
            return "Upload failed.\n\(message)"
        }
    }
}
