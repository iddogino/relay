import XCTest

/// A tour of the screens besides the terminal, screenshotting each (for
/// review), and checking each opens and closes.
final class ScreensUITests: RelayUITestCase {
    func dismissSheet() {
        for label in ["Cancel", "Done", "Close"] {
            let button = app.buttons[label].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
        app.swipeDown(velocity: .fast)
    }

    func testTour() throws {
        showList()
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"

        app.buttons["sidebar.add"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["Create"].firstMatch.waitForExistence(timeout: 5))
        shot("\(device)-create-session")
        app.buttons["Project"].firstMatch.tap()
        sleep(1)
        shot("\(device)-create-project")
        dismissSheet()

        app.buttons["sidebar.settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        shot("\(device)-settings")
        // Each step waits for the screen it leads to (a slow Simulator is
        // still animating the last one after a fixed pause).
        let settings = app.navigationBars["Settings"]
        for pane in ["Hosts", "Terminal", "Notifications", "iCloud"] {
            XCTAssertTrue(app.buttons[pane].firstMatch.waitForExistence(timeout: 5), "no \(pane) in Settings")
            app.buttons[pane].firstMatch.tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "\(pane) didn't open")
            sleep(1)
            shot("\(device)-settings-\(pane.lowercased())")
            if pane == "Hosts" {
                app.buttons.containing(.staticText, identifier: "rig").firstMatch.tap()
                let editor = app.navigationBars["Edit Host"]
                XCTAssertTrue(editor.waitForExistence(timeout: 5), "no host editor")
                sleep(1)
                shot("\(device)-host-editor")
                dismissSheet()
                XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "the host editor didn't close")
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "didn't get back to Settings from \(pane)")
        }
        dismissSheet()
    }
}
