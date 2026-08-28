import Foundation

/// Derives the stable `RTERM_SESSION_SLUG` value from a session's display
/// name: lowercase ASCII letters/digits with single dashes — safe for git
/// branch names, worktree directories, and file names.
public enum SessionSlug {
    public static let maxLength = 60

    public static func make(displayName: String, sessionID: SessionID) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in displayName.lowercased().unicodeScalars {
            let isSafe = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isSafe {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
            if slug.count > maxLength { break }
        }
        if slug.count > maxLength { slug = String(slug.prefix(maxLength)) }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty {
            // Name had no usable characters; fall back to a stable ID prefix.
            let hex = sessionID.uuid.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            slug = "s-" + String(hex.prefix(8))
        }
        return slug
    }
}
