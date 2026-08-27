import Foundation

/// POSIX shell quoting for values embedded in remote command strings.
///
/// Every dynamic value that reaches a remote `/bin/sh` must pass through
/// `quote(_:)`. The output is a single-quoted word using the standard
/// `'\''` escape for embedded single quotes, which is safe for any POSIX
/// shell regardless of content (spaces, `$`, backticks, semicolons, …).
public enum POSIXShellQuote {
    /// Returns a single shell word that expands to exactly `value`.
    public static func quote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes and joins argv into one shell command line.
    public static func quoteJoin(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    /// True if the value contains control characters (including newlines).
    /// Values used in single-line contexts should be rejected when this is true.
    public static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
