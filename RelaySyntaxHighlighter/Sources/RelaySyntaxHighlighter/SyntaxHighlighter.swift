import Foundation

/// Loads converted Prism grammars from the module bundle and caches them.
/// Grammar references (`$language`) resolve through here — lazily, so
/// cyclic references (javascript → interpolation → javascript) terminate.
public final class GrammarStore: @unchecked Sendable {
    public static let shared = GrammarStore()

    private let lock = NSLock()
    private var cache: [String: Grammar?] = [:]

    /// nil grammar for unknown/unbundled languages.
    public func grammar(for language: String) -> Grammar? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language] { return cached }
        let loaded = load(language)
        cache[language] = loaded
        return loaded
    }

    private func load(_ language: String) -> Grammar? {
        // Language ids are converter-controlled, but never let a hostile
        // string traverse paths.
        guard language.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        guard let url = Bundle.module.url(
            forResource: language, withExtension: "json", subdirectory: "Grammars")
        else { return nil }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(GrammarDocument.self, from: data)
        else { return nil }
        return Grammar(document: document)
    }

    /// Languages with a bundled grammar, for tests and diagnostics.
    public func bundledLanguages() -> [String] {
        // paths(forResourcesOfType:) returns [String] on both platforms;
        // URL accessors (lastPathComponent, path) are typed as String? on
        // swift-corelibs-foundation and don't compile cleanly on Linux.
        let paths = Bundle.module.paths(forResourcesOfType: "json", inDirectory: "Grammars")
        return paths.map { path -> String in
            let file = (path as NSString).lastPathComponent
            return (file as NSString).deletingPathExtension
        }.sorted()
    }
}

/// One flattened, leaf-level span of highlighted text.
public struct TokenRun: Sendable, Equatable {
    /// UTF-16 range in the input string.
    public let range: NSRange
    /// Token types from outermost to innermost, aliases included; empty
    /// for plain text.
    public let types: [String]
}

/// Public entry point: text + language → flat token runs.
public enum SyntaxHighlighter {
    /// nil when the language has no bundled grammar (callers render plain).
    public static func runs(for text: String, language: String) -> [TokenRun]? {
        let store = GrammarStore.shared
        guard let grammar = store.grammar(for: language) else { return nil }
        let tokenized = PrismEngine.tokenize(text, grammar: grammar) { store.grammar(for: $0) }
        let nodes = PrismPostProcessor.apply(tokenized, language: language)
        var runs: [TokenRun] = []
        var offset = 0
        flatten(nodes, typeStack: [], offset: &offset, into: &runs)
        return runs
    }

    private static func flatten(
        _ nodes: [TokenNode], typeStack: [String], offset: inout Int, into runs: inout [TokenRun]
    ) {
        for node in nodes {
            switch node {
            case .text(let s):
                emit(s, typeStack: typeStack, offset: &offset, into: &runs)
            case .token(let type, let alias, let content):
                let types = typeStack + [type] + alias
                switch content {
                case .raw(let s):
                    emit(s, typeStack: types, offset: &offset, into: &runs)
                case .stream(let inner):
                    flatten(inner, typeStack: types, offset: &offset, into: &runs)
                }
            }
        }
    }

    private static func emit(
        _ text: String, typeStack: [String], offset: inout Int, into runs: inout [TokenRun]
    ) {
        let length = (text as NSString).length
        if length > 0 {
            runs.append(TokenRun(
                range: NSRange(location: offset, length: length),
                types: typeStack))
        }
        offset += length
    }

    /// Maps a file path to a bundled language id — nil means "render plain".
    public static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let candidate: String?
        if let byName = specialFileNames[name] {
            candidate = byName
        } else {
            candidate = extensionMap[(name as NSString).pathExtension]
        }
        guard let candidate, GrammarStore.shared.grammar(for: candidate) != nil else { return nil }
        return candidate
    }

    /// File extension → Prism language id. Only ids with vendored grammars
    /// resolve (language(forPath:) verifies against the bundle), so this
    /// table may safely lead the ported set.
    static let extensionMap: [String: String] = [
        "swift": "swift",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "jsx",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "tsx",
        "py": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "json": "json",
        "yml": "yaml", "yaml": "yaml",
        "md": "markdown", "markdown": "markdown",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "css": "css",
        "html": "markup", "htm": "markup", "xml": "markup", "svg": "markup",
        "sql": "sql",
        "toml": "toml",
        "diff": "diff", "patch": "diff",
    ]

    static let specialFileNames: [String: String] = [
        "dockerfile": "docker",
        "makefile": "makefile",
    ]
}
