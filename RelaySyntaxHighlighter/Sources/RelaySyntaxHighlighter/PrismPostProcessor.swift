import Foundation

/// Post-tokenize stream transforms that Prism implements as `after-tokenize`
/// hooks rather than grammar rules. These are hand-written per language in
/// Prism (they can't be expressed as patterns), so they're hand-ported here
/// and keyed by language id — mirroring Prism's language-conditional hooks.
enum PrismPostProcessor {
    /// Applies the post-processor registered for `language`, if any.
    static func apply(_ nodes: [TokenNode], language: String) -> [TokenNode] {
        switch language {
        case "jsx", "tsx":
            var copy = nodes
            walkJSX(&copy)
            return copy
        default:
            return nodes
        }
    }

    // MARK: - JSX/TSX plain-text merging

    /// Faithful port of prism-jsx.js `walkTokens`: text sitting directly
    /// inside an open JSX tag (and not within a `{…}` expression) is Prism's
    /// "plain-text" — any tokens the grammar matched there are dropped and
    /// merged, with adjacent plain text, into a single `plain-text` token.
    private static func walkJSX(_ tokens: inout [TokenNode]) {
        struct OpenTag { let name: String; var openedBraces: Int }
        var openedTags: [OpenTag] = []

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            var notTagNorBrace = false

            if case .token(let type, _, _) = token {
                if type == "tag",
                   let inner = child(token, 0), inner.typeName == "tag" {
                    // A tag token whose first child is itself a `tag` — find
                    // which kind by inspecting its punctuation.
                    let firstPunct = child(inner, 0).flatMap(contentString)
                    if firstPunct == "</" {
                        // Closing tag: pop a matching opener.
                        let name = child(inner, 1).map(stringify) ?? ""
                        if let last = openedTags.last, last.name == name {
                            openedTags.removeLast()
                        }
                    } else if lastChildContent(token) == "/>" {
                        // Self-closing tag: ignore.
                    } else {
                        // Opening tag.
                        openedTags.append(OpenTag(name: child(inner, 1).map(stringify) ?? "", openedBraces: 0))
                    }
                } else if !openedTags.isEmpty, type == "punctuation", contentString(token) == "{" {
                    openedTags[openedTags.count - 1].openedBraces += 1
                } else if !openedTags.isEmpty, openedTags[openedTags.count - 1].openedBraces > 0,
                          type == "punctuation", contentString(token) == "}" {
                    openedTags[openedTags.count - 1].openedBraces -= 1
                } else {
                    notTagNorBrace = true
                }
            }

            if notTagNorBrace || token.isString {
                if let last = openedTags.last, last.openedBraces == 0 {
                    // Inside a tag, outside any `{…}` — plain text. Absorb
                    // adjacent plain text on both sides into one token.
                    var plainText = stringify(token)
                    if i < tokens.count - 1, isPlain(tokens[i + 1]) {
                        plainText += stringify(tokens[i + 1])
                        tokens.remove(at: i + 1)
                    }
                    if i > 0, isPlain(tokens[i - 1]) {
                        plainText = stringify(tokens[i - 1]) + plainText
                        tokens.remove(at: i - 1)
                        i -= 1
                    }
                    tokens[i] = .token(type: "plain-text", alias: [], content: .raw(plainText))
                }
            }

            // Recurse into the (possibly replaced) node's stream children.
            if case .token(let type, let alias, .stream(var children)) = tokens[i] {
                walkJSX(&children)
                tokens[i] = .token(type: type, alias: alias, content: .stream(children))
            }
            i += 1
        }
    }

    // MARK: - Prism token accessors

    /// A bare string or an already-merged plain-text token.
    private static func isPlain(_ node: TokenNode) -> Bool {
        if node.isString { return true }
        return node.typeName == "plain-text"
    }

    /// Prism `stringifyToken`: the node's leaf text.
    private static func stringify(_ node: TokenNode) -> String {
        switch node {
        case .text(let s): return s
        case .token(_, _, .raw(let s)): return s
        case .token(_, _, .stream(let content)): return content.map(stringify).joined()
        }
    }

    /// Prism `token.content[i]` for a stream token (nil for leaves / OOB).
    private static func child(_ node: TokenNode, _ index: Int) -> TokenNode? {
        guard case .token(_, _, .stream(let content)) = node, content.indices.contains(index) else {
            return nil
        }
        return content[index]
    }

    /// Prism `token.content` when compared to a string literal — only a
    /// leaf (raw or bare string) has string content; a stream does not.
    private static func contentString(_ node: TokenNode) -> String? {
        switch node {
        case .text(let s): return s
        case .token(_, _, .raw(let s)): return s
        case .token(_, _, .stream): return nil
        }
    }

    /// Prism `token.content[token.content.length - 1].content` — the last
    /// child's string content, for the `/>` self-close check.
    private static func lastChildContent(_ node: TokenNode) -> String? {
        guard case .token(_, _, .stream(let content)) = node, let last = content.last else {
            return nil
        }
        return contentString(last)
    }
}

extension TokenNode {
    var isString: Bool {
        if case .text = self { return true }
        return false
    }
    var typeName: String? {
        if case .token(let type, _, _) = self { return type }
        return nil
    }
}
