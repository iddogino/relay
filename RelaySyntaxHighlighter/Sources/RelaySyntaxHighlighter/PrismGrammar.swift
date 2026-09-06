import Foundation

/// In-memory form of one converted Prism grammar (see
/// Scripts/convert-grammars.mjs for the JSON format). Reference type on
/// purpose: grammars reference each other — including themselves — via
/// `$language` refs, and identity is what breaks the cycles.
public final class Grammar {
    /// Ordered — Prism semantics depend on rule insertion order. Immutable
    /// after init: grammars are cached and shared across threads.
    public let rules: [Rule]
    /// A `rest` reference: this grammar extends another language's rule set
    /// (appended at tokenize time, mirroring Prism's tokenize()).
    let restLanguage: String?

    init(rules: [Rule], restLanguage: String?) {
        self.rules = rules
        self.restLanguage = restLanguage
    }
}

public struct Rule: Sendable {
    /// Token type this rule produces (e.g. "comment", "string").
    public let name: String
    /// Pattern variants, tried in order.
    let patterns: [Pattern]
}

/// One compiled pattern variant.
final class Pattern: @unchecked Sendable {
    let regex: NSRegularExpression?
    /// Original JS regex source, kept for diagnostics (a nil `regex` with a
    /// non-nil source is a translation gap the tests surface).
    let source: String?
    /// Prism-style lookbehind: capture group 1 is trimmed from the match.
    let lookbehind: Bool
    /// Greedy patterns re-match against the whole remaining text and may
    /// swallow earlier tokens (Prism's rematch machinery).
    let greedy: Bool
    let alias: [String]
    let inside: Inside

    enum Inside {
        case none
        case inline(Grammar)
        case language(String)
    }

    init(regex: NSRegularExpression?, source: String?, lookbehind: Bool, greedy: Bool, alias: [String], inside: Inside) {
        self.regex = regex
        self.source = source
        self.lookbehind = lookbehind
        self.greedy = greedy
        self.alias = alias
        self.inside = inside
    }
}

extension Grammar {
    /// Patterns whose JS source exists but failed to compile after
    /// translation — each is a dialect gap that silently disables a rule,
    /// so the test suite treats any entry here as a failure. Recurses into
    /// inline `inside` grammars (referenced languages report their own).
    public func compileFailures() -> [(rule: String, pattern: String)] {
        var out: [(rule: String, pattern: String)] = []
        for rule in rules {
            for pattern in rule.patterns {
                if pattern.regex == nil, let source = pattern.source {
                    out.append((rule: rule.name, pattern: source))
                }
                if case .inline(let inner) = pattern.inside {
                    out += inner.compileFailures().map { (rule: "\(rule.name).\($0.rule)", pattern: $0.pattern) }
                }
            }
        }
        return out
    }
}

// MARK: - JSON decoding

/// Wire format mirror of the converter's output.
struct GrammarDocument: Decodable {
    let language: String
    let prismVersion: String
    let rules: [RuleDocument]
    let rest: RefDocument?
}

struct RuleDocument: Decodable {
    let name: String
    let patterns: [PatternDocument]
}

struct RefDocument: Decodable {
    let language: String?
    enum CodingKeys: String, CodingKey { case language = "$language" }
}

struct PatternDocument: Decodable {
    let pattern: String?
    let flags: String?
    let lookbehind: Bool?
    let greedy: Bool?
    let alias: [String]?
    let inside: InsideDocument?
    /// Set for constructs the converter couldn't serialize (JS functions).
    let unsupported: String?

    enum CodingKeys: String, CodingKey {
        case pattern, flags, lookbehind, greedy, alias, inside
        case unsupported = "$unsupported"
    }
}

/// `inside` is either an inline grammar `{rules: ...}` or a `$language` ref.
struct InsideDocument: Decodable {
    let language: String??
    let rules: [RuleDocument]?
    let rest: RefDocument?

    enum CodingKeys: String, CodingKey {
        case language = "$language"
        case rules, rest
    }
}

extension Grammar {
    convenience init(document: GrammarDocument) {
        self.init(
            rules: document.rules.map(Rule.init(document:)),
            restLanguage: document.rest?.language ?? nil)
    }

    convenience init(inside: InsideDocument) {
        self.init(
            rules: (inside.rules ?? []).map(Rule.init(document:)),
            restLanguage: inside.rest?.language ?? nil)
    }
}

extension Rule {
    init(document: RuleDocument) {
        self.init(name: document.name, patterns: document.patterns.map(Pattern.init(document:)))
    }
}

extension Pattern {
    convenience init(document: PatternDocument) {
        let inside: Inside
        if let doc = document.inside {
            if case let .some(language) = doc.language {
                // {"$language": null} marks an unresolvable cycle from the
                // converter; treat as no nested grammar.
                inside = language.map { .language($0) } ?? .none
            } else {
                inside = .inline(Grammar(inside: doc))
            }
        } else {
            inside = .none
        }
        // A pattern that fails to compile (unsupported construct or dialect
        // gap) is kept as a never-matching placeholder rather than failing
        // the whole grammar; compileFailures() surfaces the gap loudly in
        // the test suite.
        let regex = document.pattern.flatMap {
            try? JSRegex.compile($0, flags: document.flags ?? "")
        }
        self.init(
            regex: regex,
            source: document.pattern,
            lookbehind: document.lookbehind ?? false,
            greedy: document.greedy ?? false,
            alias: document.alias ?? [],
            inside: inside)
    }
}
