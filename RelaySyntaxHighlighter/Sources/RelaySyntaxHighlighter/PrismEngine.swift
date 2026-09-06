import Foundation

/// One node of a Prism token stream: raw text, or a typed token whose
/// content is itself a stream.
public enum TokenNode: Sendable {
    case text(String)
    indirect case token(type: String, alias: [String], content: TokenContent)
}

/// Prism keeps token content as a plain string when the pattern has no
/// `inside` grammar and as a nested stream when it does — and the fixture
/// comparison distinguishes the two (`[type, "s"]` vs `[type, ["s"]]`), so
/// the model must too.
public enum TokenContent: Sendable {
    case raw(String)
    case stream([TokenNode])
}

/// Faithful port of Prism v1.29 `tokenize`/`matchGrammar`
/// (components/prism-core.js in the pinned Prism checkout — same control
/// flow, same variable roles). All positions and lengths are UTF-16 code
/// units, matching JavaScript string semantics: the engine works on
/// NSString throughout and materializes Swift Strings only at the leaves.
public enum PrismEngine {
    /// Resolves `$language` grammar references at match time (cycles like
    /// javascript → interpolation → javascript resolve to the same object).
    public typealias LanguageResolver = (String) -> Grammar?

    public static func tokenize(_ text: String, grammar: Grammar, resolve: LanguageResolver) -> [TokenNode] {
        tokenize(text as NSString, grammar: grammar, resolve: resolve)
    }

    static func tokenize(_ text: NSString, grammar: Grammar, resolve: LanguageResolver) -> [TokenNode] {
        // Prism merges `rest` into the grammar before matching. The engine
        // appends lazily instead of mutating shared state; a rest-of-rest
        // is not chased, mirroring Prism's single-level merge.
        var rules = grammar.rules
        if let restName = grammar.restLanguage, let rest = resolve(restName) {
            rules += rest.rules
        }

        let list = LinkedList()
        list.addAfter(list.head, .string(text))
        matchGrammar(text: text, list: list, rules: rules, resolve: resolve,
                     startNode: list.head, startPos: 0, rematch: nil)
        return list.toArray()
    }

    // MARK: - Token list

    final class Value {
        enum Kind {
            case string(NSString)
            case token(type: String, alias: [String], content: TokenContent, matchedLength: Int)
        }
        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }

        var length: Int {
            switch kind {
            case .string(let s): return s.length
            case .token(_, _, _, let matchedLength): return matchedLength
            }
        }
        var isToken: Bool {
            if case .token = kind { return true }
            return false
        }
    }

    final class Node {
        var value: Value?
        var prev: Node?
        var next: Node?
    }

    final class LinkedList {
        let head = Node()
        let tail = Node()
        var count = 0

        init() {
            head.next = tail
            tail.prev = head
        }

        @discardableResult
        func addAfter(_ node: Node, _ kind: Value.Kind) -> Node {
            let new = Node()
            new.value = Value(kind)
            new.prev = node
            new.next = node.next
            node.next?.prev = new
            node.next = new
            count += 1
            return new
        }

        /// Removes up to `count` nodes after `node` (Prism's removeRange).
        func removeRange(after node: Node, count removeCount: Int) {
            var next = node.next
            var i = 0
            while i < removeCount, let n = next, n !== tail {
                next = n.next
                i += 1
            }
            node.next = next
            next?.prev = node
            count -= i
        }

        func toArray() -> [TokenNode] {
            var out: [TokenNode] = []
            var node = head.next
            while let n = node, n !== tail {
                switch n.value!.kind {
                case .string(let s):
                    out.append(.text(s as String))
                case .token(let type, let alias, let content, _):
                    out.append(.token(type: type, alias: alias, content: content))
                }
                node = n.next
            }
            return out
        }
    }

    /// Concatenating leaf text reconstructs the tokenized input exactly.
    static func leafText(_ content: TokenContent) -> String {
        switch content {
        case .raw(let s): return s
        case .stream(let nodes):
            return nodes.map {
                switch $0 {
                case .text(let s): return s
                case .token(_, _, let inner): return leafText(inner)
                }
            }.joined()
        }
    }

    /// Reference type on purpose: Prism mutates the rematch object through
    /// the recursion and callers read the updated `reach` afterwards.
    final class Rematch {
        let cause: String
        var reach: Int
        init(cause: String, reach: Int) {
            self.cause = cause
            self.reach = reach
        }
    }

    // MARK: - Matching

    /// JS `matchPattern`: exec from `pos`; Prism-style lookbehind trims the
    /// length of capture group 1 off the front of the match.
    ///
    /// `.withoutAnchoringBounds` gives JS `lastIndex` semantics (^/$ anchor
    /// to the true string boundaries, not the search-range boundaries) and
    /// `.withTransparentBounds` lets lookbehind/\b see text before `pos`,
    /// as JS `exec` does.
    private static func matchPattern(
        _ regex: NSRegularExpression, pos: Int, text: NSString, lookbehind: Bool
    ) -> (index: Int, length: Int)? {
        let range = NSRange(location: pos, length: text.length - pos)
        let options: NSRegularExpression.MatchingOptions = [.withoutAnchoringBounds, .withTransparentBounds]
        guard let m = regex.firstMatch(in: text as String, options: options, range: range) else {
            return nil
        }
        var index = m.range.location
        var length = m.range.length
        if lookbehind, m.numberOfRanges > 1 {
            let group1 = m.range(at: 1)
            if group1.location != NSNotFound, group1.length > 0 {
                index += group1.length
                length -= group1.length
            }
        }
        return (index, length)
    }

    static func matchGrammar(
        text: NSString, list: LinkedList, rules: [Rule], resolve: LanguageResolver,
        startNode: Node, startPos: Int, rematch: Rematch?
    ) {
        for rule in rules {
            for (j, pattern) in rule.patterns.enumerated() {
                if let rematch, rematch.cause == "\(rule.name),\(j)" {
                    return
                }
                guard let regex = pattern.regex else { continue }

                var currentNode = startNode.next
                var pos = startPos

                iterate: while let node = currentNode, node !== list.tail {
                    // The for-loop increment in the JS original; every
                    // `continue` below runs it, mirroring JS semantics.
                    defer {
                        if let n = currentNode, n !== list.tail {
                            pos += n.value!.length
                            currentNode = n.next
                        }
                    }

                    if let rematch, pos >= rematch.reach { break iterate }

                    if list.count > text.length {
                        // Runaway empty matches; abort like Prism does.
                        return
                    }

                    guard case .string(let nodeString) = node.value!.kind else { continue }

                    var removeCount = 1
                    let covered: NSString
                    let matchIndex: Int
                    let matchLength: Int

                    if pattern.greedy {
                        guard let m = matchPattern(regex, pos: pos, text: text, lookbehind: pattern.lookbehind),
                              m.index < text.length
                        else { break iterate }

                        let from = m.index
                        let to = m.index + m.length
                        var p = pos + node.value!.length

                        // Find the node containing the match start.
                        while from >= p, let next = currentNode!.next, next !== list.tail {
                            currentNode = next
                            p += next.value!.length
                        }
                        p -= currentNode!.value!.length
                        pos = p

                        // A match starting inside another token is invalid.
                        if currentNode!.value!.isToken { continue }

                        // Find the last node affected by this match.
                        var k: Node? = currentNode
                        while let kn = k, kn !== list.tail,
                              (p < to || !kn.value!.isToken) {
                            removeCount += 1
                            p += kn.value!.length
                            k = kn.next
                        }
                        removeCount -= 1

                        covered = text.substring(with: NSRange(location: pos, length: p - pos)) as NSString
                        matchIndex = from - pos
                        matchLength = m.length
                    } else {
                        guard let m = matchPattern(regex, pos: 0, text: nodeString, lookbehind: pattern.lookbehind) else {
                            continue
                        }
                        covered = nodeString
                        matchIndex = m.index
                        matchLength = m.length
                    }

                    let node = currentNode! // may have advanced in the greedy walk
                    let matchedString = covered.substring(with: NSRange(location: matchIndex, length: matchLength))
                    let before = covered.substring(to: matchIndex)
                    let after = covered.substring(from: matchIndex + matchLength)

                    let reach = pos + covered.length
                    if let rematch, reach > rematch.reach { rematch.reach = reach }

                    var removeFrom = node.prev!
                    if !before.isEmpty {
                        removeFrom = list.addAfter(removeFrom, .string(before as NSString))
                        pos += (before as NSString).length
                    }

                    list.removeRange(after: removeFrom, count: removeCount)

                    let content: TokenContent
                    switch pattern.inside {
                    case .none:
                        content = .raw(matchedString)
                    case .inline(let inner):
                        content = .stream(tokenize(matchedString as NSString, grammar: inner, resolve: resolve))
                    case .language(let name):
                        if let inner = resolve(name) {
                            content = .stream(tokenize(matchedString as NSString, grammar: inner, resolve: resolve))
                        } else {
                            content = .stream([.text(matchedString)])
                        }
                    }
                    let wrapped = list.addAfter(removeFrom, .token(
                        type: rule.name, alias: pattern.alias, content: content,
                        matchedLength: (matchedString as NSString).length))

                    if !after.isEmpty {
                        list.addAfter(wrapped, .string(after as NSString))
                    }

                    if removeCount > 1 {
                        // Tokens were consumed — earlier matches in the span
                        // may now be invalid; rematch it (Prism's
                        // nestedRematch), sharing reach through the object.
                        let nested = Rematch(cause: "\(rule.name),\(j)", reach: reach)
                        matchGrammar(text: text, list: list, rules: rules, resolve: resolve,
                                     startNode: wrapped.prev!, startPos: pos, rematch: nested)
                        if let rematch, nested.reach > rematch.reach {
                            rematch.reach = nested.reach
                        }
                    }

                    currentNode = wrapped
                }
            }
        }
    }
}
