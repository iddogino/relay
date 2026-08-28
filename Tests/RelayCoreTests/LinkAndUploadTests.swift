import Foundation
import Testing
@testable import RelayCore

@Suite("localhost link rewriting")
struct LocalhostURLRewriterTests {
    private func rewritten(_ raw: String, host: String = "devbox.example") -> String? {
        guard let url = URL(string: raw) else { return nil }
        return LocalhostURLRewriter.rewrite(url, remoteHost: host)?.absoluteString
    }

    @Test func rewritesLoopbackHostsPreservingEverything() {
        #expect(rewritten("http://localhost:3000") == "http://devbox.example:3000")
        #expect(rewritten("http://localhost:3000/app/path?q=1&x=%20#frag")
                == "http://devbox.example:3000/app/path?q=1&x=%20#frag")
        #expect(rewritten("https://127.0.0.1:8443/health") == "https://devbox.example:8443/health")
        #expect(rewritten("http://0.0.0.0:8080") == "http://devbox.example:8080")
        #expect(rewritten("http://[::1]:5173/") == "http://devbox.example:5173/")
        #expect(rewritten("ws://localhost:9229/debug") == "ws://devbox.example:9229/debug")
        // Default port (no explicit port) stays implicit.
        #expect(rewritten("http://localhost/") == "http://devbox.example/")
        // Case-insensitive host match.
        #expect(rewritten("http://LOCALHOST:3000") == "http://devbox.example:3000")
    }

    @Test func leavesNonLoopbackAlone() {
        #expect(rewritten("http://example.com:3000") == nil)
        #expect(rewritten("https://relay.dev/path") == nil)
        // *.localhost carries virtual-host routing a host swap would break.
        #expect(rewritten("http://app.localhost:3000") == nil)
        // Non-web schemes are never rewritten.
        #expect(rewritten("mailto:test@localhost") == nil)
        #expect(rewritten("file:///tmp/x") == nil)
        // A schemeless "localhost:3000" parses with scheme "localhost" —
        // ghostty wouldn't linkify it anyway, and we must not mangle it.
        #expect(rewritten("localhost:3000") == nil)
    }

    @Test func loopbackHostDetection() {
        #expect(LocalhostURLRewriter.isLoopbackHost("127.0.0.1"))
        #expect(LocalhostURLRewriter.isLoopbackHost("LocalHost"))
        #expect(LocalhostURLRewriter.isLoopbackHost("::1"))
        #expect(!LocalhostURLRewriter.isLoopbackHost("devbox.example"))
        #expect(!LocalhostURLRewriter.isLoopbackHost("10.0.0.5"))
    }
}

@Suite("ssh -G hostname parsing")
struct SSHHostNameResolverTests {
    @Test func parsesTypicalDump() {
        let dump = """
        user iddo
        hostname mini.tail1234.ts.net
        port 22
        addressfamily any
        """
        #expect(SSHHostNameResolver.parseHostName(fromConfigDump: dump) == "mini.tail1234.ts.net")
    }

    @Test func handlesMissingOrDegenerateValues() {
        #expect(SSHHostNameResolver.parseHostName(fromConfigDump: "port 22\nuser x") == nil)
        #expect(SSHHostNameResolver.parseHostName(fromConfigDump: "hostname \n") == nil)
        // Only the exact lowercase key matches; similar keys don't.
        #expect(SSHHostNameResolver.parseHostName(fromConfigDump: "hostnamealias foo\nhostname bar") == "bar")
    }
}

@Suite("drop upload validation")
struct DropUploadValidationTests {
    @Test func acceptsReasonableItems() throws {
        let names = try SSHTmuxRuntimeProvider.validateDropBasenames(
            ["/a/report v1.pdf", "/b/data set", "/c/notes'quote.txt", "/d/日本語.md"])
        #expect(names == ["report v1.pdf", "data set", "notes'quote.txt", "日本語.md"])
    }

    @Test func rejectsDuplicatesControlCharsAndEmpties() {
        #expect(throws: RuntimeProviderError.self) {
            _ = try SSHTmuxRuntimeProvider.validateDropBasenames(["/a/same.txt", "/b/same.txt"])
        }
        #expect(throws: RuntimeProviderError.self) {
            _ = try SSHTmuxRuntimeProvider.validateDropBasenames(["/a/bad\nname"])
        }
        #expect(throws: RuntimeProviderError.self) {
            _ = try SSHTmuxRuntimeProvider.validateDropBasenames([])
        }
        #expect(throws: RuntimeProviderError.self) {
            _ = try SSHTmuxRuntimeProvider.validateDropBasenames(["/"])
        }
    }

    @Test func dropDirectorySafetyIsStrict() {
        #expect(SSHTmuxRuntimeProvider.isSafeDropDirectory("/tmp/relay-drop.Ab12Cd34"))
        #expect(!SSHTmuxRuntimeProvider.isSafeDropDirectory("/tmp/relay-drop."))
        #expect(!SSHTmuxRuntimeProvider.isSafeDropDirectory("/tmp/other.Ab12"))
        #expect(!SSHTmuxRuntimeProvider.isSafeDropDirectory("/tmp/relay-drop.a/../../etc"))
        #expect(!SSHTmuxRuntimeProvider.isSafeDropDirectory("/tmp/relay-drop.a b"))
        #expect(!SSHTmuxRuntimeProvider.isSafeDropDirectory("/tmp/relay-drop.$(rm)"))
    }
}
