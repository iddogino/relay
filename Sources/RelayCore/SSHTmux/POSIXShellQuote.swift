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

/// A command line that runs a script under `/bin/sh` whatever the remote
/// login shell is.
///
/// sshd hands an exec request's command line to the user's login shell, and
/// no quoting of a multi-line script reads the same in all of them (csh and
/// tcsh reject a newline inside quotes). So the script travels as `printf`
/// octal escapes — backslashes and digits, inside single quotes, which
/// sh, bash, zsh, fish and csh all pass through untouched — and sh decodes
/// and evaluates it. Nothing but `/bin/sh` and its `printf` is needed on
/// the host.
public enum RemoteShCommand {
    /// `script` under `/bin/sh`, with `arguments` as `$0`, `$1`, …
    /// (each must be a plain word: they're parsed by the login shell).
    public static func line(_ script: String, arguments: [String] = []) -> String {
        (["/bin/sh", "-c", "'eval \"$(printf \"\(octal(script))\")\"'"] + arguments).joined(separator: " ")
    }

    /// A fragment of sh setting `$name` to exactly `value`, bytes the login
    /// shell never sees as such. (The `x` keeps trailing newlines, which
    /// command substitution would drop.)
    public static func assignment(_ name: String, value: String) -> String {
        "\(name)=$(printf \"\(octal(value))\"; printf x); \(name)=${\(name)%x}"
    }

    /// Each byte of `text` as a `printf` octal escape.
    public static func octal(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count * 4)
        for byte in text.utf8 {
            out += "\\"
            out += String(byte >> 6, radix: 8)
            out += String((byte >> 3) & 7, radix: 8)
            out += String(byte & 7, radix: 8)
        }
        return out
    }
}
