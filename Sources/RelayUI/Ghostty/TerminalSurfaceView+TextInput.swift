#if os(iOS)
import GhosttyKit
import UIKit

/// The software keyboard's side of the terminal beyond typing keys
/// (`UITextInput`, over `UIKeyInput`'s insert and delete):
///
/// - Its trackpad (touch and hold the space bar, or drag two fingers on the
///   keyboard) moves the terminal's cursor with arrow keys: ← or → for each
///   cell crossed, ↑ or ↓ for a move that's mostly up or down. The shell,
///   vim and the rest see the keys they already understand.
/// - Composition (Japanese, Chinese, Korean…) shows in place at the cursor,
///   as libghostty's preedit, and is sent once committed.
///
/// A terminal has no text for the keyboard to edit. The document UIKit sees
/// is a space, then the text being composed, with the caret after the space
/// (at the terminal's cursor): with nothing before the caret, the keyboard
/// wouldn't repeat its delete key while held.
struct TextInputState {
    /// The text being composed (UIKit's "marked text").
    var composing = ""
    /// The selection within it, in UTF-16 units.
    var selection = NSRange(location: 0, length: 0)
    /// Where the trackpad was when it last moved the cursor, in this view's
    /// coordinates; nil when it isn't in use.
    var trackpadAnchor: CGPoint?
}

extension TerminalSurfaceView: UITextInput {
    /// What the keyboard sees before the caret, always.
    private static let context = " "
    private var document: NSString { (Self.context + textInput.composing) as NSString }
    private var composingStart: Int { (Self.context as NSString).length }
    private var composingLength: Int { (textInput.composing as NSString).length }

    // MARK: Composition

    var markedTextRange: UITextRange? {
        textInput.composing.isEmpty ? nil : TerminalTextRange(composingStart, composingStart + composingLength)
    }

    var selectedTextRange: UITextRange? {
        get {
            let selection = textInput.selection
            return TerminalTextRange(composingStart + selection.location, composingStart + NSMaxRange(selection))
        }
        // Only within the composition: the terminal's cursor moves by keys.
        set {
            guard let range = newValue as? TerminalTextRange else { return }
            textInput.selection = clamped(NSRange(location: range.from - composingStart, length: range.to - range.from))
        }
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        textInput.composing = markedText ?? ""
        textInput.selection = clamped(selectedRange)
        showComposition()
    }

    /// Commits the composition: it's sent as typed.
    func unmarkText() {
        let committed = textInput.composing
        endComposition()
        if !committed.isEmpty { insertText(committed) }
    }

    /// Drops the composition, unsent.
    func endComposition() {
        guard !textInput.composing.isEmpty else { return }
        textInput.composing = ""
        textInput.selection = NSRange(location: 0, length: 0)
        showComposition()
    }

    private func showComposition() {
        guard let surface else { return }
        let text = textInput.composing
        if text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        }
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let start = min(max(range.location, 0), composingLength)
        return NSRange(location: start, length: min(max(range.length, 0), composingLength - start))
    }

    func text(in range: UITextRange) -> String? {
        let document = document
        guard let range = range as? TerminalTextRange, range.from >= 0, range.to <= document.length else { return nil }
        return document.substring(with: NSRange(location: range.from, length: range.to - range.from))
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? TerminalTextRange else { return }
        if range.from >= composingStart, !textInput.composing.isEmpty {
            // Within the composition: it changes, still uncommitted.
            let part = clamped(NSRange(location: range.from - composingStart, length: range.to - range.from))
            textInput.composing = (textInput.composing as NSString).replacingCharacters(in: part, with: text)
            textInput.selection = NSRange(location: part.location + (text as NSString).length, length: 0)
            showComposition()
            return
        }
        // Before the caret: deleted (with Backspace), then the text typed.
        for _ in 0..<max(0, min(range.to, composingStart) - range.from) { deleteBackward() }
        if !text.isEmpty { insertText(text) }
    }

    // MARK: Positions (in the document, in UTF-16 units)

    var beginningOfDocument: UITextPosition { TerminalTextPosition(0) }
    var endOfDocument: UITextPosition { TerminalTextPosition(document.length) }

    private func offset(_ position: UITextPosition) -> Int {
        (position as? TerminalTextPosition)?.offset ?? 0
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let (from, to) = (offset(fromPosition), offset(toPosition))
        return TerminalTextRange(min(from, to), max(from, to))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let target = self.offset(position) + offset
        return (0...document.length).contains(target) ? TerminalTextPosition(target) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left: self.position(from: position, offset: -offset)
        case .right: self.position(from: position, offset: offset)
        default: nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let (a, b) = (offset(position), offset(other))
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        offset(toPosition) - offset(from)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        direction == .left || direction == .up
            ? TerminalTextRange(0, offset(position))
            : TerminalTextRange(offset(position), document.length)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Geometry: the terminal's cursor

    /// A cell's size, in points.
    private var cellSize: CGSize {
        guard let surface else { return .zero }
        let size = ghostty_surface_size(surface)
        return CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale)
    }

    /// The cursor's cell (widened by the composition, while there is one).
    private var cursorRect: CGRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        // The cell's horizontal middle and its bottom.
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let cell = cellSize
        return CGRect(x: x - cell.width / 2, y: y - height, width: max(width, cell.width), height: height)
    }

    func firstRect(for range: UITextRange) -> CGRect { cursorRect }

    func caretRect(for position: UITextPosition) -> CGRect {
        let cursor = cursorRect
        return CGRect(x: cursor.minX, y: cursor.minY, width: 2, height: cursor.height)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: The keyboard's trackpad

    func beginFloatingCursor(at point: CGPoint) {
        textInput.trackpadAnchor = point
    }

    func updateFloatingCursor(at point: CGPoint) {
        let cell = cellSize
        guard var anchor = textInput.trackpadAnchor, cell.width > 0, cell.height > 0 else { return }
        // Across: a key per cell, each dropping any drift up or down so far,
        // so that only a move that's mostly vertical gets to ↑ or ↓ (in a
        // shell, those are the history).
        while abs(point.x - anchor.x) >= cell.width {
            let right = point.x > anchor.x
            pressNamed(right ? .right : .left, mods: GHOSTTY_MODS_NONE)
            anchor.x += right ? cell.width : -cell.width
            anchor.y = point.y
        }
        while abs(point.y - anchor.y) >= cell.height {
            let down = point.y > anchor.y
            pressNamed(down ? .down : .up, mods: GHOSTTY_MODS_NONE)
            anchor.y += down ? cell.height : -cell.height
            anchor.x = point.x
        }
        textInput.trackpadAnchor = anchor
    }

    func endFloatingCursor() {
        textInput.trackpadAnchor = nil
    }
}

/// A place in the document the keyboard sees (see `TextInputState`).
final class TerminalTextPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }
}

final class TerminalTextRange: UITextRange {
    let from: Int
    let to: Int

    init(_ from: Int, _ to: Int) {
        self.from = from
        self.to = to
    }

    override var start: UITextPosition { TerminalTextPosition(from) }
    override var end: UITextPosition { TerminalTextPosition(to) }
    override var isEmpty: Bool { from == to }
}
#endif
