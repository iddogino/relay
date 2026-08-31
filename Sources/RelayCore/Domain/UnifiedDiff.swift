import Foundation

/// One changed file in a unified diff.
public struct DiffFile: Sendable, Equatable, Identifiable {
    /// Display path (the post-change side for renames).
    public var path: String
    /// The pre-change path when the file was renamed; nil otherwise.
    public var oldPath: String?
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    public var hunks: [DiffHunk]

    public var id: String { path }

    public init(
        path: String,
        oldPath: String? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false,
        hunks: [DiffHunk] = []
    ) {
        self.path = path
        self.oldPath = oldPath
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.hunks = hunks
    }
}

public struct DiffHunk: Sendable, Equatable {
    /// The full `@@ -l,c +l,c @@ context` line.
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine] = []) {
        self.header = header
        self.lines = lines
    }
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable {
        case context, addition, deletion
        /// `\ No newline at end of file` and similar markers.
        case meta
    }

    public var kind: Kind
    /// The line without its +/-/space prefix.
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Parses `git diff` unified output into files/hunks/lines. Tolerant by
/// design: unknown header lines are skipped, and a truncated tail (the
/// provider caps very large diffs) yields whatever parsed cleanly.
public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var currentHunk: DiffHunk?
        var oldPath: String?
        var newPath: String?
        var pendingRename: (from: String?, to: String?) = (nil, nil)
        var inHunk = false

        func closeHunk() {
            if let hunk = currentHunk { current?.hunks.append(hunk) }
            currentHunk = nil
            inHunk = false
        }

        func closeFile() {
            closeHunk()
            if var file = current {
                // Prefer the +++ path; deletions (+++ /dev/null) fall back
                // to the --- side; rename headers win over both.
                if let to = pendingRename.to {
                    file.path = to
                    file.oldPath = pendingRename.from
                } else if let new = newPath, new != "/dev/null" {
                    file.path = new
                } else if let old = oldPath, old != "/dev/null" {
                    file.path = old
                }
                files.append(file)
            }
            current = nil
            oldPath = nil
            newPath = nil
            pendingRename = (nil, nil)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                closeFile()
                current = DiffFile(path: Self.pathFromDiffGitLine(line) ?? "")
                continue
            }
            guard current != nil else { continue }

            if inHunk {
                if line.hasPrefix("@@") {
                    closeHunk()
                    currentHunk = DiffHunk(header: line)
                    inHunk = true
                } else if line.hasPrefix("+") {
                    currentHunk?.lines.append(DiffLine(kind: .addition, text: String(line.dropFirst())))
                    current?.additions += 1
                } else if line.hasPrefix("-") {
                    currentHunk?.lines.append(DiffLine(kind: .deletion, text: String(line.dropFirst())))
                    current?.deletions += 1
                } else if line.hasPrefix(" ") {
                    currentHunk?.lines.append(DiffLine(kind: .context, text: String(line.dropFirst())))
                } else if line.hasPrefix("\\") {
                    currentHunk?.lines.append(DiffLine(kind: .meta, text: line))
                } else if line.isEmpty {
                    // An empty context line arrives as a single space, but be
                    // tolerant of a bare empty line too.
                    currentHunk?.lines.append(DiffLine(kind: .context, text: ""))
                } else {
                    // Anything else ends the hunk (defensive; shouldn't
                    // happen between `diff --git` boundaries).
                    closeHunk()
                }
                continue
            }

            if line.hasPrefix("@@") {
                currentHunk = DiffHunk(header: line)
                inHunk = true
            } else if line.hasPrefix("--- ") {
                oldPath = Self.stripPathPrefix(String(line.dropFirst(4)))
            } else if line.hasPrefix("+++ ") {
                newPath = Self.stripPathPrefix(String(line.dropFirst(4)))
            } else if line.hasPrefix("rename from ") {
                pendingRename.from = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                pendingRename.to = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
            }
            // index/mode/similarity headers: skipped.
        }
        closeFile()
        return files.filter { !$0.path.isEmpty }
    }

    /// "diff --git a/path b/path" → "path" (best effort; --- / +++ headers
    /// are authoritative when present). Paths with spaces make this line
    /// ambiguous, hence best effort only.
    private static func pathFromDiffGitLine(_ line: String) -> String? {
        let body = line.dropFirst("diff --git ".count)
        guard let range = body.range(of: " b/") else { return nil }
        return String(body[body.index(range.lowerBound, offsetBy: 3)...])
    }

    /// "a/path" / "b/path" → "path"; leaves "/dev/null" alone.
    private static func stripPathPrefix(_ raw: String) -> String {
        // git may append a tab + timestamp in some configs.
        let path = raw.split(separator: "\t").first.map(String.init) ?? raw
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }
}
