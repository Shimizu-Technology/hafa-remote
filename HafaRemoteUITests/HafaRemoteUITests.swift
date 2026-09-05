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

    /// Verifies that every MVP control remains discoverable and dispatches through the shared action.
    @MainActor
    func testRemoteControlSurfaceAndSelectCommand() throws {
        let app = launchRemoteHarness()

        XCTAssertTrue(app.staticTexts["remoteConnectionStatus"].waitForExistence(timeout: 5))

        let requiredCommands = [
            "up", "down", "left", "right", "select", "back", "home", "volumeDown", "mute",
            "volumeUp", "rewind", "play", "pause", "fastForward",
        ]
        for command in requiredCommands {
            let button = app.buttons["remote-\(command)"]
            XCTAssertTrue(button.waitForExistence(timeout: 2), "Missing \(command) control")
            for _ in 0..<6 where !button.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(button.isHittable, "Unreachable \(command) control")
            XCTAssertTrue(button.isEnabled, "Disabled \(command) control")
        }

        let select = app.buttons["remote-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 2))
        for _ in 0..<6 where !select.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(select.isHittable, "Unreachable select control")
        select.tap()

        let commandOutput = app.staticTexts["lastRemoteCommand"]
        XCTAssertTrue(commandOutput.waitForExistence(timeout: 2))
        XCTAssertEqual(commandOutput.label, "select")
    }

    /// Power is destructive and must never send from an accidental tap.
    @MainActor
    func testPowerRequiresConfirmation() throws {
        let app = launchRemoteHarness()
        let power = app.buttons["remote-powerOff"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        power.tap()

        XCTAssertTrue(app.staticTexts["Turn off Living Room TV?"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Turn Off"].exists)

        app.buttons["Cancel"].tap()
        let commandOutput = app.staticTexts["lastRemoteCommand"]
        XCTAssertTrue(commandOutput.waitForExistence(timeout: 2))
        XCTAssertEqual(commandOutput.label, "none")
    }

    /// The scrollable remote must remain usable at the largest accessibility text size.
    @MainActor
    func testRemoteSupportsLargestDynamicType() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing-remote",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let dynamicTypeProbe = app.staticTexts["currentDynamicTypeSize"]
        XCTAssertTrue(dynamicTypeProbe.waitForExistence(timeout: 5))
        XCTAssertEqual(dynamicTypeProbe.label, "accessibility5")
        XCTAssertTrue(app.buttons["remote-powerOff"].waitForExistence(timeout: 5))
        let keyboard = app.buttons["remote-keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
        for _ in 0..<6 where !keyboard.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(keyboard.isHittable)
        XCTAssertFalse(keyboard.isEnabled)
    }

    @MainActor
    private func launchRemoteHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-remote")
        app.launch()
        return app
    }
}
