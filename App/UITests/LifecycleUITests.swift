import XCTest

/// Leaving the app and coming back: a quick trip keeps the connection; a
/// longer one (past the grace period) closes it, and coming back
/// reconnects to the session on screen.
final class LifecycleUITests: RelayUITestCase {
    func typeAndCheck(_ label: String) {
        showKeyboard()
        clearLine()
        let text = marker(label)
        app.typeText("echo \(text)\n")
        waitForScreen(containing: "\n\(text)", timeout: 20)
    }

    func testBackgroundAndBack() throws {
        openSession()
        typeAndCheck("before")

        XCUIDevice.shared.press(.home)
        sleep(5)
        app.activate()
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        typeAndCheck("quick")

        XCUIDevice.shared.press(.home)
        sleep(40)
        app.activate()
        XCTAssertTrue(terminal.waitForExistence(timeout: 20))
        shot("back-after-long")
        typeAndCheck("long")
    }
}
