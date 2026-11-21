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

    /// Double-tapping a modifier keeps it on across keys; a tap releases it.
    func testDoubleTapLocksAModifier() throws {
        openSession()
        showKeyboard()
        let ctrl = keyBarKey("ctrl")
        XCTAssertTrue(ctrl.waitForExistence(timeout: 5), "no key bar")
        ctrl.doubleTap()
        XCTAssertEqual(ctrl.value as? String, "locked")
        // ^U clears the line, and Control stays on for the next.
        app.typeText("u")
        XCTAssertEqual(ctrl.value as? String, "locked")
        app.typeText("u")
        XCTAssertEqual(ctrl.value as? String, "locked")
        ctrl.tap()
        XCTAssertEqual(ctrl.value as? String, "off")
        let typed = marker("unlocked")
        app.typeText("echo \(typed)\n")
        waitForScreen(containing: "\n\(typed)")
    }

    /// The key bar's attach button offers the photo library and the file
    /// browser; a photo picked is uploaded to the host and its path there
    /// typed in, with the keyboard back up.
    func testAttachAPhoto() throws {
        openSession()
        showKeyboard()
        clearLine()
        let attach = keyBarKey("attach")
        XCTAssertTrue(attach.waitForExistence(timeout: 5), "no attach button")
        attach.tap()
        XCTAssertTrue(app.buttons["Choose Files"].waitForExistence(timeout: 5), "no file browser choice")
        shot("attach-menu")
        app.buttons["Photo Library"].tap()

        // The system's picker, with the Simulator's own photos.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "no photo picker:\n\(app.debugDescription)")
        photo.tap()
        let done = app.buttons["Done"].firstMatch
        let selected = Date().addingTimeInterval(5)
        while !done.isEnabled, Date() < selected { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        shot("attach-picker")
        XCTAssertTrue(done.isEnabled, "the photo wasn't selected:\n\(app.debugDescription)")
        done.tap()

        waitForScreen(containing: "/tmp/relay-drop.", timeout: 60)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard didn't come back")
        shot("attached")
        dismissKeyboardTip()
        clearLine()
    }

    /// The keys past the edge scroll into reach, and a swipe along the key
    /// bar that starts on a key scrolls without pressing it.
    func testKeyBarScrolls() throws {
        openSession()
        showKeyboard()
        let last = keyBarKey("pageDown")
        XCTAssertTrue(keyBarKey("escape").waitForExistence(timeout: 5), "no key bar")
        try XCTSkipIf(last.isHittable, "every key fits")

        // Swipes along the keys from the middle of the row, where ← is at
        // first (it would move the cursor back a character).
        clearLine()
        app.typeText("echo before")
        let keys = app.scrollViews["keybar.keys"].firstMatch
        for _ in 0..<4 where !last.isHittable {
            keys.swipeLeft()
        }
        XCTAssertTrue(last.isHittable, "the key bar didn't scroll to its last key")
        shot("keybar-scrolled")
        app.typeText("X\n")
        waitForScreen(containing: "\nbeforeX\n")

        // A key that was out of reach works.
        let tag = marker("piped")
        app.typeText("echo \(tag) ")
        keyBarKey("text.|").tap()
        app.typeText(" tr - _\n")
        waitForScreen(containing: "\n\(tag.replacingOccurrences(of: "-", with: "_"))")

        // Holding a key a moment before dragging still scrolls, not types.
        app.typeText("echo after")
        let slash = keyBarKey("text./").frame
        keys.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: keys.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertGreaterThan(keyBarKey("text./").frame.midX, slash.midX + 50, "holding then dragging didn't scroll")
        app.typeText("Y\n")
        waitForScreen(containing: "\nafterY\n")
    }

    // MARK: The software keyboard's own keys

    /// Types `keys` by tapping the software keyboard's keys. (`typeText`
    /// goes in as a hardware keyboard, which puts the software keyboard
    /// away, and around its composition.)
    func tapKeys(_ keys: String) {
        for key in keys { app.keys[key == " " ? "space" : String(key)].tap() }
    }

    var returnKey: XCUIElement { app.keyboards.buttons["Return"].firstMatch }

    /// Switches the software keyboard to Japanese (romaji) or back to
    /// English; false if the device has no such keyboard.
    @discardableResult
    func useKeyboard(japanese: Bool) -> Bool {
        let next = app.buttons["Next keyboard"].firstMatch
        let isJapanese = app.keys["削除"], isEnglish = app.keys["q"]
        for _ in 0..<5 where japanese ? !isJapanese.exists : (!isEnglish.exists || isJapanese.exists) {
            guard next.exists else { break }
            next.tap()
        }
        return japanese ? isJapanese.exists : isEnglish.exists && !isJapanese.exists
    }

    /// Waits for a line of the terminal that `matches`, and returns it.
    @discardableResult
    func waitForLine(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                     matching matches: (String) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let found = screenText.components(separatedBy: "\n").last(where: matches) { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("no line \(description); the terminal shows:\n\(screenText)", file: file, line: line)
        return nil
    }

    /// Touching and holding the space bar turns the keyboard into a
    /// trackpad, which moves the terminal's cursor (with arrow keys): across
    /// for a move that's mostly across, and up or down only for one that's
    /// mostly up or down.
    func testKeyboardTrackpad() throws {
        openSession()
        showKeyboard()
        XCTAssertTrue(useKeyboard(japanese: false), "no English keyboard")
        let space = app.keys["space"].firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 5), "no space bar")
        let center = space.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        /// Holds the space bar, then drags by `offset` (the cursor moves
        /// about half as far again).
        func drag(_ offset: CGVector) {
            center.press(forDuration: 1.2, thenDragTo: center.withOffset(offset),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
        }

        // Left and a little up: back a few cells ("echo " is five cells
        // back from the word), and no ↑ (which would recall a command).
        let word = String((0..<10).map { _ in "abcdefghijklmnopqrstuvw".randomElement()! })
        keyBarKey("ctrl").tap()
        tapKeys("u")
        tapKeys("echo \(word)")
        drag(CGVector(dx: -20, dy: -12))
        tapKeys("x")
        returnKey.tap()
        let output = waitForLine("with \(word) and an x") { $0.replacingOccurrences(of: "x", with: "") == word }
        XCTAssertNotEqual(output, word + "x", "the trackpad didn't move the cursor")
        shot("trackpad")

        // Straight up: ↑, that command again.
        drag(CGVector(dx: 0, dy: -12))
        returnKey.tap()
        waitForLine("run twice") { _ in
            self.screenText.components(separatedBy: "\n").filter { $0 == output }.count == 2
        }
    }

    /// The keyboard's delete key deletes in the terminal, a character per
    /// tap, and repeats while held; two spaces stay two spaces.
    func testKeyboardDelete() throws {
        openSession()
        showKeyboard()
        XCTAssertTrue(useKeyboard(japanese: false), "no English keyboard")
        let word = String((0..<12).map { _ in "abcdefghijklmnopqrstuvw".randomElement()! })
        keyBarKey("ctrl").tap()
        tapKeys("u")
        tapKeys("echo \(word)zz")
        /// What's typed on the shell's line: its last.
        var typed: String {
            let line = screenText.components(separatedBy: "\n").last { $0.hasPrefix("rig ") } ?? ""
            return line.components(separatedBy: "% ").dropFirst().joined(separator: "% ")
                .trimmingCharacters(in: .whitespaces)
        }
        func waitForTyped(_ description: String, _ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            XCTAssertTrue(done(), "\(description); the line is \(typed.debugDescription)")
        }

        let delete = app.keys["delete"].firstMatch
        delete.tap()
        delete.tap()
        waitForTyped("two taps didn't delete two characters") { typed == "echo \(word)" }
        // Held: it repeats; held long, it speeds up to words, still only
        // deleting.
        delete.press(forDuration: 2)
        waitForTyped("holding delete didn't repeat") {
            "echo \(word)".hasPrefix(typed) && typed.count < "echo \(word)".count - 2
        }
        tapKeys(" one two three four")
        delete.press(forDuration: 5)
        waitForTyped("holding delete long didn't delete the line") { typed.isEmpty }

        // Two spaces stay two spaces (not the keyboard's ". " shortcut).
        tapKeys("echo ok  done")
        returnKey.tap()
        waitForLine("ok done") { $0 == "ok done" }
    }

    /// Composing (with the Japanese keyboard, when the device has it) shows
    /// in place at the cursor and is sent once committed: as a candidate, or
    /// as typed with the return key (確定).
    func testComposition() throws {
        openSession()
        showKeyboard()
        XCTAssertTrue(useKeyboard(japanese: false), "no English keyboard")
        keyBarKey("ctrl").tap()
        tapKeys("u")
        tapKeys("echo ")
        try XCTSkipUnless(useKeyboard(japanese: true), "no Japanese keyboard")
        defer { useKeyboard(japanese: false) }

        tapKeys("nihon")
        let candidate = app.staticTexts["日本"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), "no candidates")
        shot("composing")
        candidate.tap()
        tapKeys("kana")
        returnKey.tap()
        // Not composing: Return.
        returnKey.tap()
        waitForScreen(containing: "\n日本かな\n")
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
