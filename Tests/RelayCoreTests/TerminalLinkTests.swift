import Foundation
import Testing
@testable import RelayCore

@Suite("terminal link classification")
struct TerminalLinkTests {
    @Test func webAndMailLinksPassThrough() {
        #expect(TerminalLink.classify("https://example.com/x?y=1")
            == .web(URL(string: "https://example.com/x?y=1")!))
        #expect(TerminalLink.classify("http://localhost:3000")
            == .web(URL(string: "http://localhost:3000")!))
        #expect(TerminalLink.classify("mailto:a@b.co")
            == .email(URL(string: "mailto:a@b.co")!))
    }

    @Test func fileURLsBecomeRemotePaths() {
        #expect(TerminalLink.classify("file:///home/iddo/report.pdf")
            == .remoteFile(path: "/home/iddo/report.pdf"))
        // Percent-encoded and host-carrying forms decode to plain paths.
        #expect(TerminalLink.classify("file://gputer/tmp/a%20b.png")
            == .remoteFile(path: "/tmp/a b.png"))
    }

    @Test func pathFormsClassifyWithLineSuffixesStripped() {
        #expect(TerminalLink.classify("/var/log/build.log")
            == .remoteFile(path: "/var/log/build.log"))
        #expect(TerminalLink.classify("./out/shot.png")
            == .remoteFile(path: "./out/shot.png"))
        #expect(TerminalLink.classify("../sibling/x.csv")
            == .remoteFile(path: "../sibling/x.csv"))
        #expect(TerminalLink.classify("~/notes.md")
            == .remoteFile(path: "~/notes.md"))
        #expect(TerminalLink.classify("src/foo.ts:120")
            == .remoteFile(path: "src/foo.ts"))
        #expect(TerminalLink.classify("Sources/App/Main.swift:12:5")
            == .remoteFile(path: "Sources/App/Main.swift"))
    }

    @Test func nonLinksAreRejected() {
        // Bare scheme-looking tokens without a path.
        #expect(TerminalLink.classify("main.rs:12") == nil)
        // Env-var paths would need remote expansion of arbitrary text.
        #expect(TerminalLink.classify("$HOME/x.txt") == nil)
        // Flag-looking text.
        #expect(TerminalLink.classify("--worktree=/x") == nil)
        #expect(TerminalLink.classify("") == nil)
        #expect(TerminalLink.classify("ssh://host/thing") == nil)
    }
}
