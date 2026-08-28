import Foundation

/// Interprets the status glyph coding agents prefix their terminal titles
/// with. Claude Code animates ◐/◑ (U+25D0/U+25D1) while the agent is
/// working and shows a static ✳ (U+2733) when it is ready for input, so a
/// single sample of the title — however stale — identifies the state.
public enum AgentActivity: Equatable, Sendable {
    /// The agent is actively working on `task`.
    case working(task: String)
    /// The agent is idle and ready for input on `task`.
    case ready(task: String)
    /// No recognized status glyph; the title is ordinary text.
    case plain(title: String)

    public static func parse(_ title: String) -> AgentActivity {
        guard let first = title.unicodeScalars.first else {
            return .plain(title: title)
        }
        // Drop the whole first grapheme so variation selectors (e.g. ✳️'s
        // U+FE0F) go with it.
        let rest = String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch first {
        case "\u{25D0}", "\u{25D1}":
            return .working(task: rest)
        case "\u{2733}":
            return .ready(task: rest)
        default:
            return .plain(title: title)
        }
    }
}
