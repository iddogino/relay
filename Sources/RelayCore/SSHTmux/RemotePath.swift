import Foundation

/// Renders a user-entered remote path into a shell expression that a remote
/// POSIX shell will expand safely.
///
/// Supported forms:
///   - `~`       → the remote `$HOME`
///   - `~/foo`   → `$HOME/foo`
///   - anything else → the literal path, quoted
///
/// No other shell expansion (`$VAR`, command substitution, globs) is supported;
/// such characters are treated as literal path characters.
public enum RemotePath {
    /// Returns a shell expression (NOT a plain string) suitable for use where
    /// a single word is expected, e.g. `cd <expr>`.
    public static func shellExpression(for input: String) -> String {
        if input == "~" {
            return "\"$HOME\""
        }
        if input.hasPrefix("~/") {
            let rest = String(input.dropFirst(2))
            if rest.isEmpty { return "\"$HOME\"" }
            return "\"$HOME\"/" + POSIXShellQuote.quote(rest)
        }
        return POSIXShellQuote.quote(input)
    }

    /// Basic sanity validation for a user-entered path.
    public static func validateInput(_ input: String) -> Result<String, RuntimeProviderError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalidInput("Folder path is required."))
        }
        guard !POSIXShellQuote.containsControlCharacters(trimmed) else {
            return .failure(.invalidInput("Folder path can't contain control characters."))
        }
        return .success(trimmed)
    }
}
