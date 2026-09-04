import XCTest

final class HafaRemoteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyStateOpensTVSetup() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Hafa Remote"].waitForExistence(timeout: 5))

        let addButton = app.buttons["addSamsungTVButton"]
        XCTAssertTrue(addButton.isHittable)
        addButton.tap()

        XCTAssertTrue(app.navigationBars["Add a TV"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["TV setup is next"].exists)
    }
}
