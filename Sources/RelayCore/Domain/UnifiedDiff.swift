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
    /// True when the file was removed (`+++ /dev/null`); it has no
    /// working-tree content, so full-file mode doesn't apply.
    public var isDeleted: Bool
    public var hunks: [DiffHunk]

    public var id: String { path }

    public init(
        path: String,
        oldPath: String? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false,
        isDeleted: Bool = false,
        hunks: [DiffHunk] = []
    ) {
        self.path = path
        self.oldPath = oldPath
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isDeleted = isDeleted
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
    /// 1-based line number in the OLD file — set for deletions and context,
    /// nil for additions and meta lines. Drives the left gutter track.
    public var oldLineNumber: Int?
    /// 1-based line number in the NEW file — set for additions and context,
    /// nil for deletions and meta lines. Drives the right gutter track.
    public var newLineNumber: Int?

    public init(kind: Kind, text: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// One line of a full-file diff view: the complete new-file content with
/// the diff's deletions spliced back in at their positions.
public struct FullFileLine: Sendable, Equatable {
    public var kind: DiffLine.Kind
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public init(kind: DiffLine.Kind, text: String, oldLineNumber: Int?, newLineNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// Reconstructs the "entire file with diffs" view: the fetched new-file
/// content, with the diff's hunks (additions tinted, deletions re-inserted
/// at their positions) overlaid, and the unchanged gaps between hunks filled
/// from the file content.
public enum FullFileReconstructor {
    /// Returns nil when the file content is too short to place the hunks
    /// (e.g. the diff and the fetched content disagree — a moving target),
    /// so callers fall back to the hunks-only view.
    public static func lines(file: DiffFile, newFileContent: String) -> [FullFileLine]? {
        // Split without a trailing synthetic empty line: git file content
        // ends in "\n", which would otherwise add a phantom last line.
        var fileLines = newFileContent.components(separatedBy: "\n")
        if fileLines.last == "" { fileLines.removeLast() }

        var out: [FullFileLine] = []
        var nextNew = 1 // 1-based index into fileLines we haven't emitted yet
        var offset = 0  // newLineNumber - oldLineNumber accumulated over hunks

        // Emits unchanged file lines [from, to) as context.
        func emitContext(upTo end: Int) -> Bool {
            while nextNew < end {
                guard nextNew - 1 < fileLines.count else { return false }
                out.append(FullFileLine(
                    kind: .context, text: fileLines[nextNew - 1],
                    oldLineNumber: nextNew - offset, newLineNumber: nextNew))
                nextNew += 1
            }
            return true
        }

        for hunk in file.hunks {
            let start = UnifiedDiffParser.hunkStarts(hunk.header).new
            guard emitContext(upTo: start) else { return nil }
            for line in hunk.lines where line.kind != .meta {
                out.append(FullFileLine(
                    kind: line.kind, text: line.text,
                    oldLineNumber: line.oldLineNumber, newLineNumber: line.newLineNumber))
                if let newNumber = line.newLineNumber { nextNew = newNumber + 1 }
            }
            // Re-derive the old/new divergence from the hunk's last numbered
            // lines so the trailing context after the last hunk lines up.
            if let lastNew = hunk.lines.compactMap(\.newLineNumber).max(),
               let lastOld = hunk.lines.compactMap(\.oldLineNumber).max() {
                offset = lastNew - lastOld
            }
        }
        _ = emitContext(upTo: fileLines.count + 1)
        return out
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
        // Running line counters for the current hunk, seeded from its
        // `@@ -oldStart,… +newStart,… @@` header.
        var oldLine = 0
        var newLine = 0

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
                    if newPath == "/dev/null" { file.isDeleted = true }
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
                    (oldLine, newLine) = Self.hunkStarts(line)
                    inHunk = true
                } else if line.hasPrefix("+") {
                    currentHunk?.lines.append(DiffLine(
                        kind: .addition, text: String(line.dropFirst()), newLineNumber: newLine))
                    newLine += 1
                    current?.additions += 1
                } else if line.hasPrefix("-") {
                    currentHunk?.lines.append(DiffLine(
                        kind: .deletion, text: String(line.dropFirst()), oldLineNumber: oldLine))
                    oldLine += 1
                    current?.deletions += 1
                } else if line.hasPrefix(" ") {
                    currentHunk?.lines.append(DiffLine(
                        kind: .context, text: String(line.dropFirst()),
                        oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1
                    newLine += 1
                } else if line.hasPrefix("\\") {
                    currentHunk?.lines.append(DiffLine(kind: .meta, text: line))
                } else if line.isEmpty {
                    // An empty context line arrives as a single space, but be
                    // tolerant of a bare empty line too.
                    currentHunk?.lines.append(DiffLine(
                        kind: .context, text: "", oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1
                    newLine += 1
                } else {
                    // Anything else ends the hunk (defensive; shouldn't
                    // happen between `diff --git` boundaries).
                    closeHunk()
                }
                continue
            }

            if line.hasPrefix("@@") {
                currentHunk = DiffHunk(header: line)
                (oldLine, newLine) = Self.hunkStarts(line)
                inHunk = true
            } else if line.hasPrefix("--- ") {
                oldPath = Self.stripPathPrefix(String(line.dropFirst(4)))
            } else if line.hasPrefix("+++ ") {
                newPath = Self.stripPathPrefix(String(line.dropFirst(4)))
            } else if line.hasPrefix("deleted file mode") {
                // Binary deletions carry no `+++ /dev/null` line, so the
                // mode header is the only deletion signal for them.
                current?.isDeleted = true
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

    /// Parses the two start line numbers from a hunk header,
    /// `@@ -oldStart[,oldCount] +newStart[,newCount] @@ …`. Defaults to
    /// (1, 1) if the header is malformed (tolerant, like the rest).
    static func hunkStarts(_ header: String) -> (old: Int, new: Int) {
        var old = 1
        var new = 1
        // Grab the "-a,b" then "+c,d" token; stop as soon as both are read
        // (and never scan past the closing "@@") so signed numbers in the
        // header's context — "@@ … @@ x = -2" — can't clobber the starts.
        let body = header.drop(while: { $0 != "-" })
        for token in body.split(separator: " ") {
            if token.hasPrefix("@@") { break }
            let sign = token.first
            guard sign == "-" || sign == "+" else { continue }
            let numberPart = token.dropFirst().prefix { $0.isNumber }
            guard let value = Int(numberPart) else { continue }
            if sign == "-" { old = value } else { new = value; break }
        }
        return (old, new)
    }

    /// The trailing context of a hunk header — the text after the closing
    /// `@@` (git's xfuncname guess, usually the enclosing declaration).
    /// Empty when the header carries none.
    public static func hunkContext(_ header: String) -> String {
        guard let open = header.range(of: "@@ "),
              let close = header.range(of: " @@", range: open.upperBound..<header.endIndex)
        else { return "" }
        return String(header[close.upperBound...]).trimmingCharacters(in: .whitespaces)
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
