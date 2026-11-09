import XCTest

/// Shared steps for driving Relay Dev on an iPhone or iPad Simulator. The
/// app must already have a host, project and session (set up through its
/// dev hooks — see Scripts/ios-ui-tests.sh); these tests only use the UI.
///
/// Environment (as `TEST_RUNNER_`-prefixed variables for xcodebuild):
/// `RELAY_UITEST_SESSION` (the session to open), `RELAY_UITEST_SHOTS` (a
/// folder for screenshots).
@MainActor
class RelayUITestCase: XCTestCase {
    var app: XCUIApplication!

    var sessionName: String { ProcessInfo.processInfo.environment["RELAY_UITEST_SESSION"] ?? "first" }

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launch()
    }

    // MARK: Elements

    var terminal: XCUIElement { app.descendants(matching: .any)["terminal"].firstMatch }

    /// What the terminal shows (its accessibility value: the visible text).
    var screenText: String { (terminal.value as? String) ?? "" }

    func keyBarKey(_ name: String) -> XCUIElement { app.buttons["keybar.\(name)"].firstMatch }

    var keyboardShown: Bool { app.keyboards.firstMatch.exists }

    // MARK: Steps

    /// iPhone: back to the session list, from a terminal (the app reopens
    /// the one last open).
    func showList() {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        if UIDevice.current.userInterfaceIdiom == .phone, back.waitForExistence(timeout: 3) {
            back.tap()
        }
    }

    /// Taps the session's row (opening its terminal) and waits for it to connect.
    func openSession(_ name: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.staticTexts[name ?? sessionName].firstMatch
        // The app reopens the session last open once it has loaded, which
        // can be after the list shows: back to the list whenever it does.
        let deadline = Date().addingTimeInterval(20)
        while !row.isHittable, Date() < deadline {
            if terminal.exists { showList() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(row.isHittable, "no row for the session", file: file, line: line)
        row.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "no terminal", file: file, line: line)
        waitForScreen(containing: "%", timeout: 20, file: file, line: line)
    }

    /// Waits until the terminal shows `text`.
    @discardableResult
    func waitForScreen(containing text: String, timeout: TimeInterval = 10,
                       file: StaticString = #filePath, line: UInt = #line) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = screenText
            if last.contains(text) { return last }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("the terminal never showed \(text.debugDescription); it shows:\n\(last)", file: file, line: line)
        return last
    }

    /// Brings up the software keyboard, past its first-run tip.
    func showKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        if !keyboardShown { terminal.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard", file: file, line: line)
        dismissKeyboardTip()
    }

    /// The keyboard's "slide to type" introduction, the first time it shows.
    func dismissKeyboardTip() {
        for candidate in [app.buttons["Continue"], app.keyboards.buttons["Continue"]] where candidate.exists {
            candidate.tap()
            return
        }
    }

    /// Clears the shell's command line (Control-U from the key bar).
    func clearLine() {
        keyBarKey("ctrl").tap()
        app.typeText("u")
    }

    /// A unique marker for checking that typing arrived.
    func marker(_ label: String) -> String {
        "\(label)-\(Int.random(in: 1000...9999))"
    }

    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["RELAY_UITEST_SHOTS"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
