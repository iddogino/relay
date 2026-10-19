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

@Suite("update channel policy")
struct UpdateChannelsTests {
    @Test func stableInstallsSeeOnlyStable() {
        #expect(UpdateChannels.allowed(currentVersion: "0.1.0", earlyBuildsOptIn: false).isEmpty)
        #expect(UpdateChannels.allowed(currentVersion: "1.2.3", earlyBuildsOptIn: false).isEmpty)
    }

    @Test func prereleaseInstallsRideTheirChannel() {
        #expect(UpdateChannels.allowed(currentVersion: "0.1.0-rc.5", earlyBuildsOptIn: false) == ["rc"])
        #expect(UpdateChannels.allowed(currentVersion: "0.2.0-beta.1", earlyBuildsOptIn: false) == ["rc"])
    }

    @Test func stableInstallsCanOptIn() {
        #expect(UpdateChannels.allowed(currentVersion: "0.1.0", earlyBuildsOptIn: true) == ["rc"])
    }
}

@Suite("scp progress meter")
struct SCPProgressParserTests {
    @Test func parsesMeterLines() {
        #expect(SCPProgressParser.parse(line: "big.iso                       45%  461MB  12.3MB/s   00:45 ETA")
                == .init(name: "big.iso", percent: 45, bytes: 461 << 20))
        // Bare byte counts have a blank unit column, then the rate.
        #expect(SCPProgressParser.parse(line: "notes.txt   100%  812   402.1KB/s   00:00")
                == .init(name: "notes.txt", percent: 100, bytes: 812))
        // Names with spaces, digits and percent signs.
        #expect(SCPProgressParser.parse(line: "my 50% file 2.zip   7% 9216KB   4.5MB/s   01:02 ETA")
                == .init(name: "my 50% file 2.zip", percent: 7, bytes: 9216 << 10))
        #expect(SCPProgressParser.parse(line: "") == nil)
        // script(1)'s stdin-EOF echo is erased by its own backspaces.
        #expect(SCPProgressParser.visibleText("^D\u{8}\u{8}a.bin   3%   30KB") == "a.bin   3%   30KB")
        #expect(SCPProgressParser.parse(line: "Warning: Permanently added 'host'") == nil)
    }

    @Test func accumulatesAcrossFilesAndRedraws() {
        var parser = SCPProgressParser()
        let stream = "a.bin   50%  512KB  1.0MB/s   00:01 ETA\ra.bin  100% 1024KB  1.0MB/s   00:01    \r\n"
            + "b.bin   25%  256KB  1.0MB/s   00:03 ETA\r"
        // Split mid-line to exercise buffering across reads.
        let bytes = Array(stream.utf8)
        #expect(parser.feed(Data(bytes[0..<20])) == nil)
        let update = parser.feed(Data(bytes[20...]))
        #expect(update == UploadProgress(bytesTransferred: (1024 + 256) << 10, currentFileFraction: 0.25, filesStarted: 2))
    }

    @Test func sameNamedFilesCountSeparately() {
        var parser = SCPProgressParser()
        _ = parser.feed(Data("x  100%  100KB  1.0MB/s   00:00\r\n".utf8))
        let update = parser.feed(Data("x   10%   10KB  1.0MB/s   00:00 ETA\r".utf8))
        #expect(update?.bytesTransferred == 110 << 10)
        #expect(update?.filesStarted == 2)
    }
}

@Suite("scp terminal wrapper")
struct ForegroundTTYCommandTests {
    /// scp only draws its meter when stdout is a tty AND its process group
    /// is that tty's foreground group (progressmeter.c can_output()).
    @Test func wrappedCommandOwnsForegroundTerminal() async throws {
        let chunks = ChunkCollector()
        let (executable, arguments) = SSHTmuxRuntimeProvider.foregroundTTYCommand(
            "/bin/sh", ["-c", "[ -t 1 ] && ps -o pgid=,tpgid= -p $$"])
        let result = try await SSHCommandRunner.runProcess(
            executable: executable,
            arguments: arguments,
            stdin: nil,
            timeout: .seconds(10),
            onStdout: { chunks.append($0) }
        )
        #expect(result.exitCode == 0)
        let ids = SCPProgressParser.nonMeterText(result.stdout).split(whereSeparator: \.isWhitespace)
        #expect(ids.count == 2)
        #expect(ids.first == ids.last)
        #expect(!chunks.isEmpty)
    }

    @Test func propagatesExitStatusAndDiagnostics() async throws {
        let (executable, arguments) = SSHTmuxRuntimeProvider.foregroundTTYCommand(
            "/bin/sh", ["-c", "echo 'scp: /nope: No such file' >&2; exit 3"])
        let result = try await SSHCommandRunner.runProcess(
            executable: executable, arguments: arguments, stdin: nil, timeout: .seconds(10))
        #expect(result.exitCode == 3)
        #expect(SCPProgressParser.nonMeterText(result.stdout) == "scp: /nope: No such file")
    }

    final class ChunkCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func append(_ data: Data) { lock.lock(); count += data.count; lock.unlock() }
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return count == 0 }
    }
}
