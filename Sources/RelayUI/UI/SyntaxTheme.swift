import AppKit
import SwiftUI
import RelaySyntaxHighlighter

/// Maps Prism token types to colors and turns a line of source into a
/// highlighted `AttributedString`. Colors are dynamic (light/dark aware) via
/// NSColor, so highlighting tracks the app's appearance for free.
///
/// Deliberately a small, muted palette: this is a changes tray, not an
/// editor. Legibility over a green/red diff tint matters more than a full
/// rainbow, so unmapped token types simply inherit the default text color.
enum SyntaxTheme {
    /// Builds a highlighted line. Returns a plain (uncolored) AttributedString
    /// when the language is unknown or has no grammar, so callers can always
    /// use the result.
    static func highlight(_ line: String, language: String?) -> AttributedString {
        var attributed = AttributedString(line)
        guard let language, let runs = SyntaxHighlighter.runs(for: line, language: language) else {
            return attributed
        }
        for run in runs {
            guard let color = color(for: run.types) else { continue }
            guard let range = Range(run.range, in: attributed, source: line) else { continue }
            attributed[range].foregroundColor = color
        }
        return attributed
    }

    /// Most specific mapped color among a token's type stack (innermost
    /// first — Prism nests, e.g. ["tag","attr-value","punctuation"]).
    private static func color(for types: [String]) -> Color? {
        for type in types.reversed() {
            if let color = palette[type] { return color }
        }
        return nil
    }

    private static let palette: [String: Color] = {
        var map: [String: Color] = [:]
        func set(_ color: Color, _ names: String...) { for n in names { map[n] = color } }

        set(.secondary, "comment", "prolog", "doctype", "cdata", "punctuation", "plain-text")
        set(dynamic(light: 0x9B2393, dark: 0xFF7AB2), "keyword", "atrule", "important", "rule", "selector")
        set(dynamic(light: 0xC41A16, dark: 0xFF8170), "string", "char", "attr-value", "regex", "url", "inserted")
        set(dynamic(light: 0x1C00CF, dark: 0xD9C97C), "number", "boolean", "constant", "symbol")
        set(dynamic(light: 0x0F68A0, dark: 0x6BDFFF), "function", "function-name", "method")
        set(dynamic(light: 0x3900A0, dark: 0xDABAFF), "class-name", "maybe-class-name", "builtin", "namespace", "type-annotation")
        set(dynamic(light: 0x804FB8, dark: 0xACF2E4), "tag", "attr-name", "property", "property-access")
        set(dynamic(light: 0x643820, dark: 0xFFA14F), "operator", "entity", "variable")
        set(dynamic(light: 0x5C2699, dark: 0xFC5FA3), "parameter")
        set(.secondary, "deleted")
        return map
    }()

    /// A light/dark hex pair as a SwiftUI Color, resolved per appearance.
    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light)
        })
    }

    private static func nsColor(hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

private extension Range where Bound == AttributedString.Index {
    /// Bridges an NSRange (UTF-16, from the highlighter) into AttributedString
    /// index space.
    init?(_ nsRange: NSRange, in attributed: AttributedString, source: String) {
        guard let stringRange = Range<String.Index>(nsRange, in: source) else { return nil }
        self.init(stringRange, in: attributed)
    }
}
