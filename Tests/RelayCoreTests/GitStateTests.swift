import Foundation
import Testing
@testable import RelayCore

@Suite("github origin parsing")
struct GitHubRemoteTests {
    @Test func parsesAllOriginForms() {
        for origin in [
            "git@github.com:iddogino/relay.git",
            "ssh://git@github.com/iddogino/relay.git",
            "https://github.com/iddogino/relay.git",
            "https://github.com/iddogino/relay",
        ] {
            #expect(GitHubRemote.webURL(fromOrigin: origin)?.absoluteString
                == "https://github.com/iddogino/relay", "failed for \(origin)")
        }
    }

    @Test func rejectsNonGitHubAndMalformedOrigins() {
        for origin in [
            "git@gitlab.com:owner/repo.git",
            "https://github.com/owner",
            "https://github.com/",
            "",
        ] {
            #expect(GitHubRemote.webURL(fromOrigin: origin) == nil, "accepted \(origin)")
        }
    }

    @Test func buildsPullRequestURL() {
        #expect(GitHubRemote.pullRequestURL(origin: "git@github.com:iddogino/relay.git", number: 42)?
            .absoluteString == "https://github.com/iddogino/relay/pull/42")
    }
}

@Suite("unified diff parsing")
struct UnifiedDiffParserTests {
    private let sample = """
    diff --git a/Sources/App/Main.swift b/Sources/App/Main.swift
    index 1111111..2222222 100644
    --- a/Sources/App/Main.swift
    +++ b/Sources/App/Main.swift
    @@ -1,4 +1,5 @@ struct Main
     import Foundation
    -let x = 1
    +let x = 2
    +let y = 3
     print(x)
    @@ -10,2 +11,2 @@
     // tail
    -old()
    +new()
    \\ No newline at end of file
    diff --git a/old-name.txt b/new-name.txt
    similarity index 90%
    rename from old-name.txt
    rename to new-name.txt
    index 3333333..4444444 100644
    --- a/old-name.txt
    +++ b/new-name.txt
    @@ -1 +1 @@
    -hello
    +goodbye
    diff --git a/logo.png b/logo.png
    index 5555555..6666666 100644
    Binary files a/logo.png and b/logo.png differ
    """

    @Test func parsesFilesHunksAndCounts() {
        let files = UnifiedDiffParser.parse(sample)
        #expect(files.count == 3)

        let main = files[0]
        #expect(main.path == "Sources/App/Main.swift")
        #expect(main.hunks.count == 2)
        #expect(main.additions == 3)
        #expect(main.deletions == 2)
        #expect(main.hunks[0].header.hasPrefix("@@ -1,4 +1,5 @@"))
        #expect(main.hunks[0].lines.map(\.kind).contains(.deletion))
        // The no-newline marker is kept as a meta line, not a change.
        #expect(main.hunks[1].lines.last?.kind == .meta)

        let renamed = files[1]
        #expect(renamed.path == "new-name.txt")
        #expect(renamed.oldPath == "old-name.txt")
        #expect(renamed.additions == 1)
        #expect(renamed.deletions == 1)

        let binary = files[2]
        #expect(binary.isBinary)
        #expect(binary.hunks.isEmpty)
    }

    @Test func assignsOldAndNewLineNumbers() {
        let files = UnifiedDiffParser.parse(sample)
        let hunk = files[0].hunks[0] // @@ -1,4 +1,5 @@
        // " import Foundation" — context, line 1 on both sides.
        #expect(hunk.lines[0].oldLineNumber == 1)
        #expect(hunk.lines[0].newLineNumber == 1)
        // "-let x = 1" — deletion, old line 2, no new number.
        #expect(hunk.lines[1].kind == .deletion)
        #expect(hunk.lines[1].oldLineNumber == 2)
        #expect(hunk.lines[1].newLineNumber == nil)
        // "+let x = 2" — addition, new line 2, no old number.
        #expect(hunk.lines[2].kind == .addition)
        #expect(hunk.lines[2].oldLineNumber == nil)
        #expect(hunk.lines[2].newLineNumber == 2)
        // "+let y = 3" — addition, new line 3.
        #expect(hunk.lines[3].newLineNumber == 3)
        // " print(x)" — context after one deletion and two additions:
        // old advanced 1→3, new advanced 1→4.
        #expect(hunk.lines[4].kind == .context)
        #expect(hunk.lines[4].oldLineNumber == 3)
        #expect(hunk.lines[4].newLineNumber == 4)

        // Second hunk reseeds from its own header (@@ -10,2 +11,2 @@).
        let second = files[0].hunks[1]
        #expect(second.lines[0].oldLineNumber == 10)
        #expect(second.lines[0].newLineNumber == 11)
    }

    @Test func reconstructsFullFileWithDiffs() throws {
        // A file whose new content is 6 lines; one hunk replaces line 2.
        let diff = """
        diff --git a/f.txt b/f.txt
        index 1..2 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         one
        -two-old
        +two-new
         three
        """
        let file = UnifiedDiffParser.parse(diff)[0]
        let newContent = "one\ntwo-new\nthree\nfour\nfive\nsix\n"
        let lines = FullFileReconstructor.lines(file: file, newFileContent: newContent)
        let rows = try #require(lines)

        // Hunk region: context "one", deletion "two-old", addition "two-new",
        // context "three".
        #expect(rows[0].kind == .context)
        #expect(rows[0].text == "one")
        #expect(rows[0].oldLineNumber == 1 && rows[0].newLineNumber == 1)
        #expect(rows[1].kind == .deletion && rows[1].text == "two-old")
        #expect(rows[1].oldLineNumber == 2 && rows[1].newLineNumber == nil)
        #expect(rows[2].kind == .addition && rows[2].text == "two-new")
        #expect(rows[2].newLineNumber == 2)
        #expect(rows[3].kind == .context && rows[3].text == "three")
        // Unchanged tail pulled from the fetched file content, correctly
        // numbered (old = new here, since additions == deletions in the hunk).
        #expect(rows[4].text == "four" && rows[4].kind == .context)
        #expect(rows[4].oldLineNumber == 4 && rows[4].newLineNumber == 4)
        #expect(rows.last?.text == "six" && rows.last?.newLineNumber == 6)
    }

    @Test func hunkStartsParsesHeaderForms() {
        // -1,4 +1,5 → both sides START at line 1 (4 and 5 are counts).
        #expect(UnifiedDiffParser.hunkStarts("@@ -1,4 +1,5 @@ struct Main") == (1, 1))
        #expect(UnifiedDiffParser.hunkStarts("@@ -10,2 +11,2 @@") == (10, 11))
        // Single-line hunks omit the count.
        #expect(UnifiedDiffParser.hunkStarts("@@ -1 +1 @@") == (1, 1))
        // Pure addition into an empty old side.
        #expect(UnifiedDiffParser.hunkStarts("@@ -0,0 +1,3 @@") == (0, 1))
        // Signed numbers in the context (git's xfuncname guess) must not
        // clobber the starts.
        #expect(UnifiedDiffParser.hunkStarts("@@ -10,2 +11,2 @@ let x = -2") == (10, 11))
        #expect(UnifiedDiffParser.hunkStarts("@@ -3,4 +5,6 @@ f(a: Int = +7)") == (3, 5))
    }

    @Test func hunkContextExtractsTrailingText() {
        #expect(UnifiedDiffParser.hunkContext("@@ -1,4 +1,5 @@ struct Main") == "struct Main")
        #expect(UnifiedDiffParser.hunkContext("@@ -10,2 +11,2 @@") == "")
        #expect(UnifiedDiffParser.hunkContext("@@ -1 +1 @@ func f()") == "func f()")
        #expect(UnifiedDiffParser.hunkContext("not a header") == "")
    }

    @Test func deletedFileKeepsItsOldPath() {
        let diff = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].path == "gone.txt")
        #expect(files[0].deletions == 1)
        #expect(files[0].isDeleted)
    }

    @Test func flagsBinaryDeletionWithoutNullPathHeader() {
        // Binary deletions carry no `+++ /dev/null` line — only the mode
        // header signals the removal.
        let diff = """
        diff --git a/logo.png b/logo.png
        deleted file mode 100644
        index 5555555..0000000
        Binary files a/logo.png and /dev/null differ
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].isDeleted)
        #expect(files[0].isBinary)
    }

    @Test func modifiedAndRenamedFilesAreNotFlaggedDeleted() {
        let files = UnifiedDiffParser.parse(sample)
        #expect(files.allSatisfy { !$0.isDeleted })
    }

    @Test func truncatedTailParsesCleanPrefix() {
        // Cut mid-hunk, as the byte cap would.
        let truncated = String(sample.prefix(200))
        let files = UnifiedDiffParser.parse(truncated)
        #expect(files.count == 1)
        #expect(files[0].path == "Sources/App/Main.swift")
    }

    @Test func emptyInputYieldsNoFiles() {
        #expect(UnifiedDiffParser.parse("").isEmpty)
        #expect(UnifiedDiffParser.parse("not a diff at all\n").isEmpty)
    }
}
