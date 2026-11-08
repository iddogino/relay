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
        for pane in ["Hosts", "Terminal", "Notifications", "iCloud"] {
            app.buttons[pane].firstMatch.tap()
            sleep(1)
            shot("\(device)-settings-\(pane.lowercased())")
            if pane == "Hosts" {
                app.buttons.containing(.staticText, identifier: "rig").firstMatch.tap()
                sleep(2)
                shot("\(device)-host-editor")
                dismissSheet()
                sleep(1)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
        dismissSheet()
    }
}
