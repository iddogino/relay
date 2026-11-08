import XCTest

/// The terminal screen with the software keyboard and the key bar, as on
/// an iPhone (or an iPad without a keyboard attached).
final class TerminalUITests: RelayUITestCase {
    /// Typing on the software keyboard reaches the session; the key bar's
    /// keys and sticky Control work; hiding the keyboard gives the terminal
    /// its room back.
    func testSoftwareKeyboardAndKeyBar() throws {
        openSession()
        // From no keyboard (in the Simulator the terminal may take focus at
        // once: it reports a hardware keyboard).
        if keyboardShown { keyBarKey("hideKeyboard").tap() }
        let hidden = Date().addingTimeInterval(5)
        while keyboardShown, Date() < hidden { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        shot("terminal")
        let fullHeight = terminal.frame.height

        showKeyboard()
        XCTAssertTrue(keyBarKey("escape").waitForExistence(timeout: 5), "no key bar")
        shot("keyboard")
        XCTAssertLessThan(terminal.frame.height, fullHeight - 200, "the terminal didn't make room for the keyboard")

        let typed = marker("typed")
        clearLine()
        app.typeText("echo \(typed)\n")
        waitForScreen(containing: "\n\(typed)")

        // Control from the key bar, for the next key: interrupts.
        app.typeText("sleep 30\n")
        keyBarKey("ctrl").tap()
        XCTAssertEqual(keyBarKey("ctrl").value as? String, "on for the next key")
        app.typeText("c")
        waitForScreen(containing: "^C")
        XCTAssertEqual(keyBarKey("ctrl").value as? String, "off")

        // Arrows: Up recalls the last command.
        let recalled = marker("recalled")
        app.typeText("echo \(recalled)\n")
        waitForScreen(containing: "\n\(recalled)")
        keyBarKey("up").tap()
        app.typeText("\n")
        let screen = waitForScreen(containing: "\n\(recalled)\n")
        XCTAssertEqual(screen.components(separatedBy: "\n\(recalled)").count - 1, 2, screen)

        keyBarKey("hideKeyboard").tap()
        let deadline = Date().addingTimeInterval(5)
        while keyboardShown, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(keyboardShown)
        XCTAssertEqual(terminal.frame.height, fullHeight, accuracy: 2)
        shot("keyboard-hidden")
    }

    /// Turning the phone resizes the terminal; turning back restores it.
    func testRotation() throws {
        openSession()
        let portrait = terminal.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        let deadline = Date().addingTimeInterval(5)
        while terminal.frame.width <= portrait.width, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertGreaterThan(terminal.frame.width, portrait.width)
        let wide = marker("wide")
        showKeyboard()
        clearLine()
        app.typeText("printf '%s %s\\n' \(wide) \"$(tput cols)\"\n")
        waitForScreen(containing: "\n\(wide) ")
        shot("landscape")
        XCUIDevice.shared.orientation = .portrait
    }
}
