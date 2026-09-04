import Foundation
import Testing
@testable import RelayCore

@Suite("directory completion")
struct DirectoryCompletionTests {
    @Test func splitsTypicalInputs() {
        #expect(DirectoryCompletion.split("~") == .init(parent: "~", partial: ""))
        #expect(DirectoryCompletion.split("~/") == .init(parent: "~", partial: ""))
        #expect(DirectoryCompletion.split("~/co") == .init(parent: "~", partial: "co"))
        #expect(DirectoryCompletion.split("~/code/re") == .init(parent: "~/code", partial: "re"))
        #expect(DirectoryCompletion.split("~/code/") == .init(parent: "~/code", partial: ""))
        #expect(DirectoryCompletion.split("/") == .init(parent: "/", partial: ""))
        #expect(DirectoryCompletion.split("/usr/lo") == .init(parent: "/usr", partial: "lo"))
        // Relative input lists the SSH login directory (the home).
        #expect(DirectoryCompletion.split("co") == .init(parent: ".", partial: "co"))
        #expect(DirectoryCompletion.split("") == .init(parent: ".", partial: ""))
    }

    @Test func acceptSplicesEntryAndDescends() {
        #expect(DirectoryCompletion.accept(input: "~", entry: "code") == "~/code/")
        #expect(DirectoryCompletion.accept(input: "~/co", entry: "code") == "~/code/")
        #expect(DirectoryCompletion.accept(input: "~/code/re", entry: "relay") == "~/code/relay/")
        #expect(DirectoryCompletion.accept(input: "/usr/lo", entry: "local") == "/usr/local/")
        #expect(DirectoryCompletion.accept(input: "/", entry: "opt") == "/opt/")
        #expect(DirectoryCompletion.accept(input: "co", entry: "code") == "code/")
        // Names with spaces splice verbatim — quoting is the script's job.
        #expect(DirectoryCompletion.accept(input: "~/My ", entry: "My Projects") == "~/My Projects/")
    }

    @Test func matchesFilterAndOrder() {
        let entries = ["Zebra", "code", "Code Reviews", ".config", ".cache", "docs"]
        // Case-insensitive prefix match, alphabetical, hidden excluded.
        #expect(DirectoryCompletion.matches(entries: entries, partial: "co")
                == ["code", "Code Reviews"])
        #expect(DirectoryCompletion.matches(entries: entries, partial: "")
                == ["code", "Code Reviews", "docs", "Zebra"])
        // A dot-leading partial opts into hidden entries.
        #expect(DirectoryCompletion.matches(entries: entries, partial: ".c")
                == [".cache", ".config"])
        #expect(DirectoryCompletion.matches(entries: entries, partial: "nope").isEmpty)
    }
}

@Suite("directory listing script")
struct DirectoryListingScriptTests {
    @Test func scriptQuotesAndCaps() {
        let script = SSHTmuxScripts.listChildDirectories(pathInput: "~/My Projects")
        // Tilde expands remotely; the rest of the path rides quoted.
        #expect(script.contains("\"$HOME\"/'My Projects'"))
        #expect(script.contains("RTERM_STATUS=ok"))
        // Entries carry the D prefix so they can't be confused with markers.
        #expect(script.contains("printf 'D%s\\n'"))
        #expect(script.contains("head -n \(SSHTmuxScripts.directoryListCap)"))
        // A missing directory is a state, not an error.
        #expect(script.contains("RTERM_STATUS=no_dir"))
        #expect(script.contains("exit 0"))
    }

    @Test func hostilePathStaysQuoted() {
        let script = SSHTmuxScripts.listChildDirectories(pathInput: "/tmp/$(rm -rf ~)/x")
        #expect(script.contains("'/tmp/$(rm -rf ~)/x'"))
    }
}
