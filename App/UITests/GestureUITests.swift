import UIKit
import XCTest

/// Touch on the terminal: drag through the scrollback, pinch the text
/// size, long-press to select and copy, paste from the key bar.
final class GestureUITests: RelayUITestCase {
    /// The terminal's width in columns, as the shell sees it.
    func columns() -> Int { tput("cols") }

    /// `tput <capability>`'s answer, from the shell in the terminal.
    func tput(_ capability: String) -> Int {
        let tag = marker(capability)
        clearLine()
        app.typeText("echo \(tag)=$(tput \(capability))\n")
        let screen = waitForScreen(containing: "\n\(tag)=")
        let line = screen.components(separatedBy: "\n").last { $0.hasPrefix("\(tag)=") } ?? ""
        return Int(line.dropFirst(tag.count + 1).trimmingCharacters(in: .whitespaces)) ?? 0
    }

    func testScrollPinchSelectAndPaste() throws {
        openSession()
        showKeyboard()

        // Scrollback: 300 numbered lines, then drag down to go back.
        clearLine()
        app.typeText("clear; seq -f 'line-%03g' 1 300\n")
        waitForScreen(containing: "line-300")
        keyBarKey("hideKeyboard").tap()
        terminal.swipeDown(velocity: .slow)
        let back = screenText
        XCTAssertFalse(back.contains("line-300"), "dragging didn't scroll back:\n\(back)")
        shot("scrolled-back")
        // A flick down keeps going (momentum); a flick up comes back.
        terminal.swipeDown(velocity: .fast)
        terminal.swipeDown(velocity: .fast)
        let further = screenText
        XCTAssertNotEqual(further, back, "a flick didn't scroll further")
        for _ in 0..<6 { terminal.swipeUp(velocity: .fast) }
        waitForScreen(containing: "line-300")

        // Pinch: bigger text, fewer columns — and it sticks.
        terminal.tap()
        showKeyboard()
        let before = columns()
        keyBarKey("hideKeyboard").tap()
        terminal.pinch(withScale: 1.6, velocity: 1)
        showKeyboard()
        let after = columns()
        XCTAssertGreaterThan(before, 0)
        XCTAssertLessThan(after, before, "pinching out didn't enlarge the text")
        shot("pinched")
        keyBarKey("hideKeyboard").tap()
        terminal.pinch(withScale: 1 / 1.6, velocity: -1)
        showKeyboard()
        XCTAssertGreaterThan(columns(), after, "pinching in didn't shrink the text")

        try selectAndPaste()
    }

    func selectAndPaste() throws {
        // Select by long-press and drag, then Copy from the edit menu.
        let word = marker("copyme")
        keyBarKey("hideKeyboard").tap()
        terminal.tap()
        let (rows, cols) = (tput("lines"), tput("cols"))
        clearLine()
        app.typeText("clear; echo \(word)\n")
        // Clearing took the command's line: the output is the first row.
        waitForScreen(containing: "\(word)\n")
        keyBarKey("hideKeyboard").tap()
        // The cell size is the terminal's size over its grid (with the
        // keyboard hidden, as it was measured).
        let cell = CGSize(width: terminal.frame.width / CGFloat(cols), height: terminal.frame.height / CGFloat(rows))
        // From the word's end back to the first column: a touch that starts
        // at the screen's left edge is the system's swipe back.
        // Past its end (copying drops the blanks after it).
        let first = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: cell.width * 0.2, dy: cell.height * 0.5))
        let last = first.withOffset(CGVector(dx: cell.width * (CGFloat(word.count) + 2), dy: 0))
        last.press(forDuration: 0.6, thenDragTo: first)
        let copy = app.menuItems["Copy"].firstMatch
        if !copy.waitForExistence(timeout: 5) { shot("no-edit-menu") }
        XCTAssertTrue(copy.exists, "no edit menu after selecting")
        shot("selected")
        copy.tap()

        // Paste from the key bar: the copied text lands on the command line.
        showKeyboard()
        clearLine()
        app.typeText("echo pasted:")
        keyBarKey("paste").tap()
        app.typeText("\n")
        waitForScreen(containing: "\npasted:\(word)")
    }

    /// A paste that could break out of its bracketing (tmux brackets every
    /// paste) — and run what follows as typed — asks first, as on the Mac.
    func testUnsafePasteAsksFirst() throws {
        openSession()
        showKeyboard()
        clearLine()
        // Whatever happens, the command line is left empty for the next test.
        addTeardownBlock { @MainActor in self.clearLine() }
        let pasted = marker("pasted")
        UIPasteboard.general.string = "echo \(pasted)\u{1B}[201~"
        let alert = app.alerts["Confirm Paste"]

        keyBarKey("paste").tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "an unsafe paste didn't ask first")
        shot("confirm-paste")
        alert.buttons["Cancel"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(screenText.contains(pasted), "a cancelled paste arrived anyway")
        // The terminal has the keyboard back (past its first-run tip).
        showKeyboard()

        keyBarKey("paste").tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "an unsafe paste didn't ask first")
        alert.buttons["Paste"].tap()
        waitForScreen(containing: "echo \(pasted)")

        // A safe one (bracketed lines) goes straight in.
        clearLine()
        let safe = marker("safe")
        UIPasteboard.general.string = "echo \(safe)"
        keyBarKey("paste").tap()
        waitForScreen(containing: "echo \(safe)")
        XCTAssertFalse(alert.exists, "a safe paste asked")
    }
}
