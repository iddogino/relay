import Foundation

/// Translates JavaScript regex sources (Prism's dialect) into
/// NSRegularExpression (ICU) equivalents.
///
/// The dialects are close, but not identical. Differences handled here:
///  - `\d \D \w \W` are ASCII-only in JS but Unicode-aware in ICU —
///    rewritten to explicit ASCII classes (context-aware: inside a character
///    class they expand to bare ranges, outside to a bracketed class).
///  - `[^]` (JS "any char including newlines") has no ICU equivalent —
///    rewritten to `[\s\S]`.
///  - An empty character class `[]` never matches in JS but is a syntax
///    error in ICU — rewritten to a never-matching lookahead.
///  - `\b \B` differ on non-ASCII word characters (ICU is Unicode-aware);
///    left as-is — diff content is overwhelmingly ASCII and the fixture
///    suites guard the rest.
///
/// Flags: `i m s` map to ICU options; `u` has no direct ICU counterpart
/// (ICU is always Unicode; property escapes work in both) and is dropped;
/// `g`/`y` are engine concerns, stripped by the converter.
enum JSRegex {
    static func compile(_ source: String, flags: String) throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        return try NSRegularExpression(pattern: translate(source), options: options)
    }

    /// Rewrites JS-dialect constructs to ICU. Scans with escape and
    /// character-class awareness; everything unrecognized passes through.
    static func translate(_ source: String) -> String {
        var out = String()
        out.reserveCapacity(source.count + 16)
        let chars = Array(source)
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "d": out += inClass ? "0-9" : "[0-9]"
                case "D": out += inClass ? "\\D" : "[^0-9]" // \D inside a class is rare and unrepresentable as a range; keep ICU's
                case "w": out += inClass ? "a-zA-Z0-9_" : "[a-zA-Z0-9_]"
                case "W": out += inClass ? "\\W" : "[^a-zA-Z0-9_]"
                default:
                    out.append(c)
                    out.append(next)
                }
                i += 2
                continue
            }
            if inClass {
                if c == "]" {
                    inClass = false
                } else if c == "[" {
                    // JS allows a bare "[" inside a class; ICU would parse
                    // it as a nested class.
                    out += "\\["
                    i += 1
                    continue
                }
                out.append(c)
                i += 1
                continue
            }
            if c == "[" {
                // "[^]" → any char; "[]" → never matches.
                if i + 2 < chars.count, chars[i + 1] == "^", chars[i + 2] == "]" {
                    out += "[\\s\\S]"
                    i += 3
                    continue
                }
                if i + 1 < chars.count, chars[i + 1] == "]" {
                    out += "(?!\\x{10FFFF})\\x{10FFFF}" // never matches
                    i += 2
                    continue
                }
                inClass = true
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
