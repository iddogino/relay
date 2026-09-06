import Foundation
import Testing
@testable import RelaySyntaxHighlighter

/// Runs the vendored Prism language test suites (Tests/…/Fixtures/<lang>/
/// *.test) against our engine + converted grammars. Format and comparison
/// semantics mirror Prism's own runner (tests/helper/test-case.js and
/// token-stream-transformer.js):
///  - a .test file is code, `----------` separator, expected JSON token
///    stream, optional description — parts trimmed;
///  - the actual stream is "simplified" before comparison: tokens become
///    [type, content] pairs and whitespace-only plain strings are dropped,
///    recursively.
///
/// Set PRISM_LANG=<lang> to restrict a run to one language (used by the
/// porting workflow).
struct PrismFixtureTests {
    struct FixtureCase: CustomTestStringConvertible, Sendable {
        let language: String
        let file: URL
        var testDescription: String { "\(language)/\(file.lastPathComponent)" }
    }

    static func allCases() throws -> [FixtureCase] {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            return []
        }
        let filter = ProcessInfo.processInfo.environment["PRISM_LANG"]
        let langDirs = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
            .filter { filter == nil || $0.lastPathComponent == filter }
        return try langDirs.flatMap { dir in
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "test" }
                // *.html.test fixtures assert Prism's HTML rendering, not its
                // token stream (a separate upstream runner). We port only the
                // tokenizer, so those aren't ours to satisfy.
                .filter { !$0.lastPathComponent.hasSuffix(".html.test") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { FixtureCase(language: dir.lastPathComponent, file: $0) }
        }.sorted { $0.testDescription < $1.testDescription }
    }

    @Test(arguments: try allCases())
    func fixture(_ testCase: FixtureCase) throws {
        let raw = try String(contentsOf: testCase.file, encoding: .utf8)
        // Prism's runner normalizes the whole file to CRLF before parsing
        // (fixtures were generated from CRLF code; checkouts are mixed).
        let content = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let parts = Self.splitTestFile(content)
        try #require(parts.count >= 2, "fixture has no expected section")
        let code = parts[0]
        let expectedJSON = parts[1]
        try #require(!expectedJSON.isEmpty, "fixture has an empty expected section")

        let store = GrammarStore.shared
        let grammar = try #require(store.grammar(for: testCase.language),
                                   "no grammar bundled for \(testCase.language)")
        let tokens = PrismEngine.tokenize(code, grammar: grammar) { store.grammar(for: $0) }
        // Apply any language-conditional post-tokenize pass (jsx/tsx
        // plain-text merging), exactly as the public API does.
        let processed = PrismPostProcessor.apply(tokens, language: testCase.language)
        let actual = Self.simplify(processed)
        let expected = try JSONSerialization.jsonObject(
            with: Data(expectedJSON.utf8), options: [.fragmentsAllowed])

        let matches = (actual as NSArray).isEqual(to: expected as? [Any] ?? [])
        if !matches {
            let actualString = Self.json(actual)
            let expectedString = Self.json(expected)
            Issue.record("""
                \(testCase.testDescription): token stream mismatch
                --- expected ---
                \(expectedString)
                --- actual ---
                \(actualString)
                """)
        }
    }

    /// Every pattern in every bundled grammar must compile — a pattern that
    /// doesn't is a silently disabled rule (a JS→ICU translation gap).
    @Test func allBundledGrammarPatternsCompile() {
        let store = GrammarStore.shared
        for language in store.bundledLanguages() {
            guard let grammar = store.grammar(for: language) else { continue }
            for failure in grammar.compileFailures() {
                Issue.record("\(language): rule '\(failure.rule)' failed to compile: /\(failure.pattern)/")
            }
        }
    }

    /// A parameterized test over zero cases passes silently — so if fixture
    /// discovery ever breaks (a moved resource, a bundle path divergence),
    /// this is what fails instead of the suite going green and vacuous.
    @Test func fixtureDiscoveryIsNotVacuous() throws {
        guard ProcessInfo.processInfo.environment["PRISM_LANG"] == nil else { return }
        #expect(try Self.allCases().count >= 200)
        #expect(GrammarStore.shared.bundledLanguages().count >= 20)
    }

    /// Prism splits on /^-{10,}[ \t]*$/m into at most 3 parts, trimming each.
    static func splitTestFile(_ content: String) -> [String] {
        let separator = try! NSRegularExpression(pattern: "^-{10,}[ \\t]*$", options: [.anchorsMatchLines])
        let ns = content as NSString
        var parts: [String] = []
        var start = 0
        for match in separator.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
            if parts.count == 2 { break } // max 3 parts, like split(..., 3)
        }
        parts.append(ns.substring(from: start))
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Prism's TokenStreamTransformer.simplify as a JSON-object builder:
    /// strings stay strings (whitespace-only ones dropped), tokens become
    /// [type, simplified content] pairs.
    static func simplify(_ nodes: [TokenNode]) -> [Any] {
        nodes.compactMap { node -> Any? in
            switch node {
            case .text(let s):
                let isBlank = s.allSatisfy(\.isWhitespace)
                return isBlank ? nil : s
            case .token(let type, _, .raw(let s)):
                return [type, s]
            case .token(let type, _, .stream(let content)):
                return [type, simplify(content)]
            }
        }
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.fragmentsAllowed]),
            let string = String(data: data, encoding: .utf8)
        else { return "<unencodable>" }
        return string
    }
}
