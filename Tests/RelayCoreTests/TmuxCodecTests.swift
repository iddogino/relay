import Foundation
import Testing
@testable import RelayCore

@Suite("tmux naming")
struct TmuxNamingTests {
    @Test func generatedNamesAreSafeAndPrefixed() {
        for _ in 0..<200 {
            let name = TmuxNaming.generateSessionName()
            #expect(name.hasPrefix("rterm-"))
            #expect(TmuxNaming.isSafeSessionName(name))
            #expect(name.allSatisfy { $0.isASCII })
        }
    }

    @Test func generatedNamesDoNotCollide() {
        var seen = Set<String>()
        for _ in 0..<10_000 {
            #expect(seen.insert(TmuxNaming.generateSessionName()).inserted)
        }
    }

    @Test func unsafeNamesRejected() {
        #expect(!TmuxNaming.isSafeSessionName("other-session"))
        #expect(!TmuxNaming.isSafeSessionName("rterm-abc; rm -rf /"))
        #expect(!TmuxNaming.isSafeSessionName("rterm-ünïcode"))
        #expect(!TmuxNaming.isSafeSessionName("rterm-a b"))
        #expect(!TmuxNaming.isSafeSessionName(""))
        #expect(TmuxNaming.isSafeSessionName("rterm-e2e-20260827-4f91c8"))
    }
}

@Suite("tmux session codec")
struct TmuxCodecTests {
    private func makeLine(
        name: String = "rterm-2f8a17d9d71e4dbe",
        schema: String = "1",
        projectID: String = UUID().uuidString,
        sessionID: String = UUID().uuidString,
        nameB64: String = TmuxSessionCodec.encodeDisplayName("my session"),
        createdAt: String = "1724800000",
        slug: String = "my-session",
        host: String = "remote-box.local",
        paneTitle: String = "✳ fixing auth flow"
    ) -> String {
        [name, schema, projectID, sessionID, nameB64, createdAt, slug, host, paneTitle]
            .joined(separator: "\t")
    }

    @Test func roundTripsUnicodeDisplayNames() {
        for name in ["plain", "with spaces", "日本語セッション", "emoji 🚀🔥", "quote ' \" $PATH; echo nope"] {
            let encoded = TmuxSessionCodec.encodeDisplayName(name)
            #expect(!encoded.contains("\t"))
            #expect(TmuxSessionCodec.decodeDisplayName(encoded) == name)
        }
    }

    @Test func parsesWellFormedLine() throws {
        let projectUUID = UUID()
        let line = makeLine(projectID: projectUUID.uuidString)
        let parsed = try #require(TmuxSessionCodec.parse(line: line))
        #expect(parsed.tmuxName == "rterm-2f8a17d9d71e4dbe")
        #expect(parsed.projectID == ProjectID(uuid: projectUUID))
        #expect(parsed.displayName == "my session")
        #expect(parsed.createdAt == Date(timeIntervalSince1970: 1_724_800_000))
        #expect(parsed.launchSlug == "my-session")
        #expect(parsed.paneTitle == "✳ fixing auth flow")
    }

    @Test func slugDegradesToNilInsteadOfPoisoning() throws {
        // Sessions created before slugs were recorded render the field empty.
        let absent = try #require(TmuxSessionCodec.parse(line: makeLine(slug: "")))
        #expect(absent.launchSlug == nil)
        // The slug lands in cleanup-hook shell environments — a mangled
        // value degrades to "not recorded", never adopted.
        let hostile = try #require(TmuxSessionCodec.parse(line: makeLine(slug: "$(rm -rf ~)")))
        #expect(hostile.launchSlug == nil)
        let uppercase = try #require(TmuxSessionCodec.parse(line: makeLine(slug: "Not-A-Slug")))
        #expect(uppercase.launchSlug == nil)
    }

    @Test func paneTitleNoiseBecomesNil() throws {
        // tmux defaults an untouched pane's title to the server hostname.
        let defaulted = try #require(TmuxSessionCodec.parse(
            line: makeLine(host: "box.local", paneTitle: "box.local")))
        #expect(defaulted.paneTitle == nil)
        let empty = try #require(TmuxSessionCodec.parse(line: makeLine(paneTitle: "")))
        #expect(empty.paneTitle == nil)
        let blank = try #require(TmuxSessionCodec.parse(line: makeLine(paneTitle: "   ")))
        #expect(blank.paneTitle == nil)
    }

    @Test func paneTitleMayContainTheSeparator() throws {
        // pane_title is free text; everything past the host field is title.
        let parsed = try #require(TmuxSessionCodec.parse(
            line: makeLine(paneTitle: "left\tright")))
        #expect(parsed.paneTitle == "left\tright")
    }

    @Test func rejectsUnknownSchema() {
        #expect(TmuxSessionCodec.parse(line: makeLine(schema: "2")) == nil)
        #expect(TmuxSessionCodec.parse(line: makeLine(schema: "")) == nil)
    }

    @Test func rejectsMalformedMetadata() {
        #expect(TmuxSessionCodec.parse(line: "") == nil)
        #expect(TmuxSessionCodec.parse(line: "just-a-name") == nil)
        #expect(TmuxSessionCodec.parse(line: makeLine(projectID: "not-a-uuid")) == nil)
        #expect(TmuxSessionCodec.parse(line: makeLine(sessionID: "nope")) == nil)
        #expect(TmuxSessionCodec.parse(line: makeLine(nameB64: "!!! not base64 !!!")) == nil)
        #expect(TmuxSessionCodec.parse(line: makeLine(createdAt: "not-a-number")) == nil)
        // Too few fields (a line in an older query format is not adopted).
        let short = ["rterm-2f8a17d9d71e4dbe", "1", UUID().uuidString, UUID().uuidString,
                     TmuxSessionCodec.encodeDisplayName("x"), "123"].joined(separator: "\t")
        #expect(TmuxSessionCodec.parse(line: short) == nil)
    }

    @Test func rejectsForeignSessions() {
        // A session not created by the app (name without our prefix) is never
        // adopted even if it happens to carry look-alike fields.
        let line = ["users-own-session", "1", UUID().uuidString, UUID().uuidString,
                    TmuxSessionCodec.encodeDisplayName("x"), "123", "x-slug", "h", "t"]
            .joined(separator: "\t")
        #expect(TmuxSessionCodec.parse(line: line) == nil)
    }
}

@Suite("tmux version parsing")
struct TmuxVersionTests {
    @Test func parsesCommonFormats() {
        #expect(SSHTmuxRuntimeProvider.parseTmuxVersion("tmux 3.4")! == (3, 4))
        #expect(SSHTmuxRuntimeProvider.parseTmuxVersion("tmux 3.7c")! == (3, 7))
        #expect(SSHTmuxRuntimeProvider.parseTmuxVersion("tmux next-3.6")! == (3, 6))
        #expect(SSHTmuxRuntimeProvider.parseTmuxVersion("tmux openbsd-7.4") == nil || SSHTmuxRuntimeProvider.parseTmuxVersion("tmux openbsd-7.4")! == (7, 4))
        #expect(SSHTmuxRuntimeProvider.parseTmuxVersion("unknown") == nil)
    }
}

@Suite("session slug")
struct SessionSlugTests {
    private let id = SessionID()

    @Test func slugifiesTypicalNames() {
        #expect(SessionSlug.make(displayName: "Fix Auth Flow!", sessionID: id) == "fix-auth-flow")
        #expect(SessionSlug.make(displayName: "  spaces   everywhere  ", sessionID: id) == "spaces-everywhere")
        #expect(SessionSlug.make(displayName: "v2.1-release (hotfix)", sessionID: id) == "v2-1-release-hotfix")
        #expect(SessionSlug.make(displayName: "already-good-123", sessionID: id) == "already-good-123")
    }

    @Test func nonASCIIBecomesDashes() {
        #expect(SessionSlug.make(displayName: "日本語 test 🚀", sessionID: id) == "test")
        #expect(SessionSlug.make(displayName: "café-menü", sessionID: id) == "caf-men")
    }

    @Test func degenerateNamesFallBackToID() {
        let slug = SessionSlug.make(displayName: "!!! $$$ ()", sessionID: id)
        #expect(slug.hasPrefix("s-"))
        #expect(slug.count == 10)
        // Stable for the same session.
        #expect(SessionSlug.make(displayName: "???", sessionID: id) == slug)
    }

    @Test func longNamesAreBounded() {
        let slug = SessionSlug.make(displayName: String(repeating: "word ", count: 40), sessionID: id)
        #expect(slug.count <= SessionSlug.maxLength)
        #expect(!slug.hasSuffix("-"))
    }

    @Test func slugIsAlwaysShellAndGitSafe() {
        for name in ["a b", "x/y\\z", "quote'\"", "$PATH `cmd`", "-lead", "日本 語"] {
            let slug = SessionSlug.make(displayName: name, sessionID: id)
            #expect(slug.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" })
            #expect(!slug.hasPrefix("-"))
        }
    }
}

@Suite("safe executable paths")
struct SafeExecutablePathTests {
    @Test func acceptsNormalPaths() {
        #expect(SSHTmuxRuntimeProvider.isSafeExecutablePath("/opt/homebrew/bin/tmux"))
        #expect(SSHTmuxRuntimeProvider.isSafeExecutablePath("/usr/bin/tmux"))
    }

    @Test func rejectsRiskyPaths() {
        #expect(!SSHTmuxRuntimeProvider.isSafeExecutablePath("tmux"))
        #expect(!SSHTmuxRuntimeProvider.isSafeExecutablePath("/path with space/tmux"))
        #expect(!SSHTmuxRuntimeProvider.isSafeExecutablePath("/tmp/$(evil)/tmux"))
        #expect(!SSHTmuxRuntimeProvider.isSafeExecutablePath(""))
    }
}
