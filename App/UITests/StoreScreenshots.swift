import XCTest

/// The App Store's screenshots (Scripts/store-screenshots.sh): not a test of
/// anything. The script sets up a demo host with the sessions named here,
/// already showing what they should; this walks the app through the screens
/// and keeps a picture of each. Skipped unless the script runs it
/// (`RELAY_STORE_SHOTS`, the folder for the pictures).
final class StoreScreenshots: RelayUITestCase {
    private var folder: String? { ProcessInfo.processInfo.environment["RELAY_STORE_SHOTS"] }
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() async throws {
        try XCTSkipIf(folder == nil, "run by Scripts/store-screenshots.sh")
        try await super.setUp()
    }

    private func keep(_ name: String) {
        guard let folder else { return }
        // Settled: no scroll indicators, no animation midway.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(pad ? "ipad" : "iphone")-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    /// The software keyboard comes up with a terminal; most pictures are of
    /// the terminal alone.
    private func hideKeyboard() {
        guard app.keyboards.firstMatch.waitForExistence(timeout: 3) else { return }
        dismissKeyboardTip()
        keyBarKey("hideKeyboard").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    private func open(_ name: String, showing text: String) {
        if !pad, terminal.exists, !terminal.frame.isEmpty { showList() }
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no row for \(name)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        row.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "no terminal")
        waitForScreen(containing: text, timeout: 30)
    }

    func testScreens() throws {
        if pad { XCUIDevice.shared.orientation = .landscapeLeft }

        // The list first (an iPhone reopens the terminal last open). On
        // screen by frame, as RelayUITestCase.openSession tells.
        let first = app.staticTexts["auth-refactor"].firstMatch
        let window = app.windows.firstMatch
        func onScreen(_ element: XCUIElement) -> Bool {
            element.exists && !element.frame.isEmpty && window.frame.contains(element.frame)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let terminalShown = !pad && onScreen(terminal)
            if onScreen(first), !terminalShown { break }
            if terminalShown { showList() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(onScreen(first), "no session list")

        if pad {
            open("auth-refactor", showing: "passed")
            hideKeyboard()
            keep("1-sessions")
            open("sweep-lr", showing: "epoch 12")
            hideKeyboard()
            keep("2-training")
        } else {
            keep("1-sessions")
            open("auth-refactor", showing: "passed")
            showKeyboard()
            keep("2-terminal")
            hideKeyboard()
            open("sweep-lr", showing: "epoch 12")
            hideKeyboard()
            keep("3-training")
        }

        // What the session changed.
        open("auth-refactor", showing: "passed")
        hideKeyboard()
        let changes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Changes:'")).firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 40), "no changes button")
        let settled = Date().addingTimeInterval(40)
        while changes.label.hasPrefix("Changes: 0 added"), Date() < settled {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        changes.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        keep(pad ? "3-diff" : "4-diff")
    }
}
