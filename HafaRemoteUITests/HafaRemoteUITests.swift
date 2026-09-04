import XCTest

/// End-to-end checks for the first-launch Hafa Remote experience.
final class HafaRemoteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Verifies that the primary empty-state action remains discoverable and opens setup.
    @MainActor
    func testEmptyStateOpensTVSetup() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Hafa Remote"].waitForExistence(timeout: 5))

        let addButton = app.buttons["addSamsungTVButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        XCTAssertTrue(addButton.isHittable)
        addButton.tap()

        XCTAssertTrue(app.navigationBars["Add Samsung TV"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["tvIPAddressField"].waitForExistence(timeout: 2))

        let connectButton = app.buttons["connectToTVButton"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 2))
        XCTAssertFalse(connectButton.isEnabled)
    }
}
