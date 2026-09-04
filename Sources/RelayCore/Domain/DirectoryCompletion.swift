import Foundation

/// Pure logic behind the project-folder autocomplete: the UI fetches (and
/// caches) one remote listing per parent directory, and everything else —
/// deciding which directory to list, filtering as the user types, splicing
/// an accepted entry back into the input — happens locally through these.
public enum DirectoryCompletion {
    public struct Split: Equatable, Sendable {
        /// The directory whose children should be listed.
        public let parent: String
        /// The component being typed, matched against the listing locally.
        public let partial: String

        public init(parent: String, partial: String) {
            self.parent = parent
            self.partial = partial
        }
    }

    /// Splits the in-progress folder input into the parent to list and the
    /// partial component after the last `/`. A bare `~` lists the remote
    /// home; a relative input without a slash lists `.` (the SSH login
    /// directory, which is the home).
    public static func split(_ input: String) -> Split {
        if input == "~" { return Split(parent: "~", partial: "") }
        guard let slash = input.lastIndex(of: "/") else {
            return Split(parent: ".", partial: input)
        }
        let partial = String(input[input.index(after: slash)...])
        if slash == input.startIndex { return Split(parent: "/", partial: partial) }
        return Split(parent: String(input[..<slash]), partial: partial)
    }

    /// Filters a parent's child directories against the typed partial:
    /// case-insensitive prefix match, hidden entries only once the partial
    /// itself starts with a dot.
    public static func matches(entries: [String], partial: String) -> [String] {
        let showHidden = partial.hasPrefix(".")
        let lowered = partial.lowercased()
        return entries
            .filter { entry in
                if entry.hasPrefix("."), !showHidden { return false }
                return lowered.isEmpty || entry.lowercased().hasPrefix(lowered)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Replaces the typed partial with an accepted entry, leaving a trailing
    /// `/` so the next level's suggestions appear immediately.
    public static func accept(input: String, entry: String) -> String {
        if input == "~" { return "~/\(entry)/" }
        guard let slash = input.lastIndex(of: "/") else { return "\(entry)/" }
        return String(input[...slash]) + entry + "/"
    }
}
