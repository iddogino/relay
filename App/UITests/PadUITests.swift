import XCTest

/// iPad: the Mac's layout (sessions beside the terminal) and a hardware
/// keyboard. Needs sessions "alpha" and "beta" (first in the sidebar) and
/// "gamma" in another project.
final class PadUITests: RelayUITestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
    }

    /// Types `text` key by key on the hardware keyboard.
    func typeOnKeyboard(_ text: String) {
        for character in text {
            switch character {
            // XCUITest's typeKey Return and Escape never reach the app in
            // the Simulator; typeText's Return does (as text).
            case "\n": app.typeText("\n")
            case " ": app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
            case let c where c.isUppercase: app.typeKey(c.lowercased(), modifierFlags: .shift)
            default: app.typeKey(String(character), modifierFlags: [])
            }
        }
    }

    func waitForTitle(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["terminal.title"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if title.exists, title.label.hasPrefix("\(name),") { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("the terminal is \(title.exists ? title.label : "not shown"), not \(name)", file: file, line: line)
    }

    /// Sessions beside the terminal, in both orientations; tapping a row
    /// switches the terminal.
    func testSplitLayout() throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            openSession("alpha")
            waitForTitle("alpha")
            XCTAssertTrue(app.staticTexts["beta"].isHittable, "the sidebar isn't beside the terminal")
            openSession("gamma")
            waitForTitle("gamma")
            shot("pad-\(orientation == .portrait ? "portrait" : "landscape")")
        }
    }

    /// A hardware keyboard: keys straight to the terminal (no software
    /// keyboard), Control and Option (as Alt) combinations, Escape and
    /// arrows; ⌘ shortcuts stay the app's.
    func testHardwareKeyboard() throws {
        openSession("alpha")
        waitForTitle("alpha")
        terminal.tap()

        // Clear the line, then type.
        app.typeKey("u", modifierFlags: .control)
        let typed = marker("hw")
        typeOnKeyboard("echo \(typed)\n")
        waitForScreen(containing: "\n\(typed)")

        // Control-C interrupts.
        typeOnKeyboard("sleep 30\n")
        app.typeKey("c", modifierFlags: .control)
        waitForScreen(containing: "^C")

        // Option is Alt: Option-B moves back a word in the shell.
        app.typeKey("u", modifierFlags: .control)
        typeOnKeyboard("echo one two")
        app.typeKey("b", modifierFlags: .option)
        typeOnKeyboard("X")
        typeOnKeyboard("\n")
        waitForScreen(containing: "\none Xtwo")

        // Arrows: Up recalls it; Control-U clears.
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        waitForScreen(containing: "% echo one Xtwo")
        app.typeKey("u", modifierFlags: .control)
        shot("pad-hardware-keyboard")

        // ⌘2 is the app's: the second session in the sidebar.
        app.typeKey("2", modifierFlags: .command)
        waitForTitle("beta")
        app.typeKey("1", modifierFlags: .command)
        waitForTitle("alpha")
    }
}
