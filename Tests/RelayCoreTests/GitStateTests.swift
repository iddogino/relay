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
