import XCTest

/// The session list and the way into and out of terminals.
final class NavigationUITests: RelayUITestCase {
    /// The session list's row for `name`.
    func row(_ name: String) -> XCUIElement {
        // The row reads as its name, with the connection as its value.
        app.staticTexts[name].firstMatch
    }

    func waitForRow(_ name: String, value: String, timeout: TimeInterval = 15,
                    file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (row(name).value as? String) == value { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("\(name) is \(row(name).value ?? "nil"), not \(value)", file: file, line: line)
    }

    func goBack() { showList() }

    /// iPhone: one connection at a time — the session last on screen. Its
    /// terminal stays connected on the list; opening another drops it.
    func testOneConnectionOnPhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        showList()
        shot("list")
        openSession("first")
        goBack()
        waitForRow("first", value: "connected")
        shot("list-first-connected")

        openSession("second")
        goBack()
        waitForRow("second", value: "connected")
        waitForRow("first", value: "not connected")
        shot("list-second-connected")

        // Back into the first: it reconnects.
        openSession("first")
        goBack()
        waitForRow("first", value: "connected")
        waitForRow("second", value: "not connected")
    }
}
