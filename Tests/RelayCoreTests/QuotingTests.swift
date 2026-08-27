import Foundation
import Testing
@testable import RelayCore

@Suite("POSIX shell quoting")
struct QuotingTests {
    static let nastyValues: [String] = [
        "simple",
        "with spaces here",
        "single'quote",
        "double\"quote",
        "dollar$HOME and ${X}",
        "semi;colon && chain || other",
        "back`tick` $(subshell)",
        "(parens) [brackets] {braces}",
        "unicode ünïcödé 日本語 🚀",
        "-leading-dash",
        "star* question? tilde~",
        "backslash\\path",
        "!history",
        "",
    ]

    @Test("round-trips through /bin/sh", arguments: nastyValues)
    func roundTrip(value: String) async throws {
        let quoted = POSIXShellQuote.quote(value)
        let result = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \(quoted)"],
            stdin: nil,
            timeout: .seconds(10)
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == value)
    }

    @Test func controlCharactersDetected() {
        #expect(POSIXShellQuote.containsControlCharacters("a\nb"))
        #expect(POSIXShellQuote.containsControlCharacters("a\tb"))
        #expect(POSIXShellQuote.containsControlCharacters("bell\u{07}"))
        #expect(!POSIXShellQuote.containsControlCharacters("plain text"))
        #expect(!POSIXShellQuote.containsControlCharacters("日本語"))
    }

    @Test func newlineSurvivesQuoting() async throws {
        // Newlines are legal inside single quotes; higher layers decide
        // whether to reject them for single-line contexts.
        let value = "line1\nline2"
        let quoted = POSIXShellQuote.quote(value)
        let result = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \(quoted)"],
            stdin: nil,
            timeout: .seconds(10)
        )
        #expect(result.stdout == value)
    }

    @Test func quoteJoin() {
        #expect(POSIXShellQuote.quoteJoin(["a b", "c"]) == "'a b' 'c'")
    }
}

@Suite("Remote path rendering")
struct RemotePathTests {
    private func evaluate(_ expression: String, home: String = "/home/testuser") async throws -> String {
        let result = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "HOME=\(POSIXShellQuote.quote(home)); export HOME; printf '%s' \(expression)"],
            stdin: nil,
            timeout: .seconds(10)
        )
        #expect(result.exitCode == 0)
        return result.stdout
    }

    @Test func bareTilde() async throws {
        let expr = RemotePath.shellExpression(for: "~")
        #expect(try await evaluate(expr) == "/home/testuser")
    }

    @Test func tildeSlash() async throws {
        let expr = RemotePath.shellExpression(for: "~/code/my-app")
        #expect(try await evaluate(expr) == "/home/testuser/code/my-app")
    }

    @Test func tildeWithSpaces() async throws {
        let expr = RemotePath.shellExpression(for: "~/My Projects/iOS App")
        #expect(try await evaluate(expr) == "/home/testuser/My Projects/iOS App")
    }

    @Test func apostropheInPath() async throws {
        let expr = RemotePath.shellExpression(for: "~/it's mine")
        #expect(try await evaluate(expr) == "/home/testuser/it's mine")
    }

    @Test func absolutePath() async throws {
        let expr = RemotePath.shellExpression(for: "/srv/data/app")
        #expect(try await evaluate(expr) == "/srv/data/app")
    }

    @Test func literalDollarIsNotExpanded() async throws {
        let expr = RemotePath.shellExpression(for: "/tmp/$HOME/literal")
        #expect(try await evaluate(expr) == "/tmp/$HOME/literal")
    }

    @Test func tildeUserIsLiteral() async throws {
        // `~otheruser/foo` is not supported expansion; it stays literal.
        let expr = RemotePath.shellExpression(for: "~otheruser/foo")
        #expect(try await evaluate(expr) == "~otheruser/foo")
    }

    @Test func inputValidation() {
        #expect(throws: Never.self) { try RemotePath.validateInput("~/ok").get() }
        if case .success = RemotePath.validateInput("") {
            Issue.record("empty path should fail")
        }
        if case .success = RemotePath.validateInput("bad\npath") {
            Issue.record("control characters should fail")
        }
    }
}
