import Foundation

/// Naming and metadata encoding for app-owned tmux sessions.
public enum TmuxNaming {
    public static let prefix = "rterm-"

    /// Generates an opaque, ASCII-safe tmux session name. Contains no
    /// user-provided text.
    public static func generateSessionName(prefix: String = TmuxNaming.prefix) -> String {
        var generator = SystemRandomNumberGenerator()
        let a = UInt64.random(in: .min ... .max, using: &generator)
        return prefix + String(format: "%016llx", a)
    }

    /// True if the name is a safe tmux identifier the app may target with
    /// destructive commands: our prefix plus `[A-Za-z0-9-]` only.
    public static func isSafeSessionName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        guard name.count <= 128 else { return false }
        return name.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "-")
        }
    }
}

/// One session row parsed from tmux `list-sessions` output.
public struct TmuxDiscoveredSession: Sendable, Equatable {
    public let tmuxName: String
    public let projectID: ProjectID
    public let sessionID: SessionID
    public let displayName: String
    public let createdAt: Date
    /// The active pane's title (set by OSC escape sequences — e.g. Claude
    /// Code's "✳ task" status). nil when unset (tmux defaults it to the
    /// remote hostname, which carries no information).
    public let paneTitle: String?
}

/// Encodes/decodes the `@rterm_*` tmux user options that mark app-owned sessions.
public enum TmuxSessionCodec {
    public static let schemaVersion = "1"
    public static let fieldSeparator: Character = "\t"

    /// tmux -F format string producing one parseable line per session.
    /// `pane_title` (the active pane of each session's current window) is
    /// last because it is free text that may itself contain the separator.
    public static var listFormat: String {
        [
            "#{session_name}",
            "#{@rterm_schema}",
            "#{@rterm_project_id}",
            "#{@rterm_session_id}",
            "#{@rterm_session_name_b64}",
            "#{@rterm_created_at}",
            "#{host}",
            "#{pane_title}",
        ].joined(separator: String(fieldSeparator))
    }

    public static func encodeDisplayName(_ name: String) -> String {
        Data(name.utf8).base64EncodedString()
    }

    public static func decodeDisplayName(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parses one output line. Returns nil for malformed lines, unknown
    /// schemas, and sessions the app does not own.
    public static func parse(line: String) -> TmuxDiscoveredSession? {
        let fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= 8 else { return nil }
        let tmuxName = fields[0]
        guard TmuxNaming.isSafeSessionName(tmuxName) else { return nil }
        guard fields[1] == schemaVersion else { return nil }
        guard let projectUUID = UUID(uuidString: fields[2]),
              let sessionUUID = UUID(uuidString: fields[3]),
              let displayName = decodeDisplayName(fields[4]),
              let createdAtEpoch = TimeInterval(fields[5])
        else { return nil }

        // Everything past the host field is the pane title verbatim (it may
        // contain the separator). tmux defaults an untouched pane's title to
        // the server hostname — that is noise, not a status.
        let host = fields[6]
        let title = fields[7...].joined(separator: String(fieldSeparator))
            .trimmingCharacters(in: .whitespaces)

        return TmuxDiscoveredSession(
            tmuxName: tmuxName,
            projectID: ProjectID(uuid: projectUUID),
            sessionID: SessionID(uuid: sessionUUID),
            displayName: displayName,
            createdAt: Date(timeIntervalSince1970: createdAtEpoch),
            paneTitle: (title.isEmpty || title == host) ? nil : title
        )
    }
}
