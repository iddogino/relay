import Foundation

/// Classifies text the terminal's link detector matched (ghostty's matcher
/// covers scheme URLs, absolute/dot-relative/`~/` paths, and bare relative
/// paths like `src/main.swift`). The session runs on a remote machine, so a
/// file-ish match means a REMOTE file.
public enum TerminalLink: Equatable, Sendable {
    case web(URL)
    case email(URL)
    /// A file on the session's machine, as written (absolute, `~/`, `./`,
    /// `../`, or cwd-relative). Trailing `:line(:col)` suffixes — tool
    /// output like `src/foo.ts:12:5` — are stripped.
    case remoteFile(path: String)

    public static func classify(_ text: String) -> TerminalLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return .web(url)
            case "mailto":
                return .email(url)
            case "file":
                // Percent-decoded; any host component is assumed to be the
                // session's machine.
                let path = url.path
                return path.isEmpty ? nil : .remoteFile(path: stripLineSuffix(path))
            default:
                // Real other schemes (ssh://, git://, …) have no preview
                // story. Bare tokens like "main.rs:12" also parse as a
                // "scheme" but lack the //, so they fall through to the
                // path rules below.
                if trimmed.hasPrefix("\(scheme)://") { return nil }
            }
        }

        let candidate = stripLineSuffix(trimmed)
        // $VAR/... paths would need remote expansion of arbitrary text; skip.
        guard candidate.contains("/"), !candidate.hasPrefix("$"), !candidate.hasPrefix("-") else {
            return nil
        }
        return .remoteFile(path: candidate)
    }

    /// "path.ts:12" / "path.ts:12:5" → "path.ts".
    private static func stripLineSuffix(_ path: String) -> String {
        path.replacing(/:\d+(?::\d+)?$/, with: "")
    }
}
