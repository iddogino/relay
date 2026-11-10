import XCTest

/// The diff tray and the GitHub sign-in, on iPhone and iPad.
final class TraysUITests: RelayUITestCase {
    func testDiffTrayAndGitHubSignIn() throws {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        openSession(device == "pad" ? "alpha" : "first")
        let changes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Changes:'")).firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 40), "no changes button")
        let deadline = Date().addingTimeInterval(40)
        while changes.label.hasPrefix("Changes: 0 added"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        changes.tap()
        sleep(3)
        shot("\(device)-diff")
        if device == "phone" {
            app.swipeDown(velocity: .fast)
        } else {
            changes.tap()
        }
        sleep(1)

        showList()
        app.buttons["sidebar.settings"].firstMatch.tap()
        app.buttons["Sign In to GitHub…"].firstMatch.tap()
        sleep(3)
        shot("\(device)-github")
    }
}
