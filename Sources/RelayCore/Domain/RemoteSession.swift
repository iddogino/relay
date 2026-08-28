import Foundation

/// A persistent remote execution session. For the SSH+tmux provider this is
/// one ordinary tmux session, but nothing above the provider may assume that.
public struct RemoteSession: Identifiable, Sendable, Hashable, Codable {
    public let id: SessionID
    public let projectID: ProjectID
    public let displayName: String
    public let createdAt: Date
    /// Provider-specific opaque identifier (the tmux session name for SSH+tmux).
    public let backendID: String
    /// Live terminal title reported by whatever runs inside the session (OSC
    /// title sequences — e.g. Claude Code's "✳ task" status). Available even
    /// for detached sessions; nil when nothing has set a title.
    public var paneTitle: String?

    public init(
        id: SessionID,
        projectID: ProjectID,
        displayName: String,
        createdAt: Date,
        backendID: String,
        paneTitle: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.displayName = displayName
        self.createdAt = createdAt
        self.backendID = backendID
        self.paneTitle = paneTitle
    }
}

/// Request payload for creating a session.
public struct NewSessionRequest: Sendable {
    public let displayName: String
    /// When false, the session opens a plain shell even if the project has a
    /// launch command configured.
    public let runLaunchCommand: Bool
    /// Extra provider metadata attached to the created session. Keys must
    /// begin with `@` (tmux user options for SSH+tmux). Used by the live E2E
    /// harness for run tagging; the production UI passes none.
    public let extraMetadata: [String: String]

    public init(
        displayName: String,
        runLaunchCommand: Bool = true,
        extraMetadata: [String: String] = [:]
    ) {
        self.displayName = displayName
        self.runLaunchCommand = runLaunchCommand
        self.extraMetadata = extraMetadata
    }
}

public enum SessionNameValidator {
    public static let maxLength = 100

    /// Validates a session display name per spec: required, trimmed,
    /// 1–100 characters, no control characters or newlines. Unicode allowed.
    public static func validate(_ raw: String) -> Result<String, RuntimeProviderError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalidInput("Session name is required."))
        }
        guard trimmed.count <= maxLength else {
            return .failure(.invalidInput("Session name must be \(maxLength) characters or fewer."))
        }
        for scalar in trimmed.unicodeScalars {
            if scalar.properties.generalCategory == .control {
                return .failure(.invalidInput("Session name can't contain control characters."))
            }
        }
        return .success(trimmed)
    }
}
