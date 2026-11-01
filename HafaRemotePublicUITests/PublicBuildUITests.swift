import XCTest

final class PublicBuildUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testUnpairedHelpAndOfflineDemo() throws {
        let app = launch("-ui-testing-discovery-empty")
        app.buttons["homeHelpButton"].tap()
        XCTAssertTrue(app.buttons["supportTVHelpButton"].waitForExistence(timeout: 5))
        app.buttons["supportTVHelpButton"].tap()
        XCTAssertTrue(
            app.staticTexts["Choose Allow when the TV asks to approve Hafa Remote."].waitForExistence(
                timeout: 5))
        XCTAssertFalse(app.staticTexts["Samsung"].exists)
        XCTAssertFalse(app.staticTexts["Sony"].exists)
        XCTAssertFalse(app.staticTexts["Vizio"].exists)
        let aboutDone = app.buttons["tvHelpDoneButton"]
        aboutDone.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: aboutDone)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 5))
        let demo = app.buttons["openOfflineDemoButton"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: demo)
        waitForExpectations(timeout: 5)
        app.buttons["openOfflineDemoButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["offlineDemoLabel"].waitForExistence(timeout: 5))
        let select = app.buttons["demo-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        XCTAssertEqual(app.staticTexts["demoActivity"].label, "Opened Watch in the demo.")
    }

    @MainActor
    func testFirstLaunchOffersTheOfflineDemo() throws {
        let app = launch("-ui-testing-discovery-empty")
        let demo = app.buttons["emptyStateDemoButton"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["offlineDemoLabel"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testManualSetupNamesNoManufacturer() throws {
        let app = launch("-ui-testing-discovery-empty")
        app.buttons["addTVButton"].tap()
        XCTAssertTrue(app.staticTexts["tvBuildSupportDescription"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["tvBuildSupportDescription"].label.contains("approve Hafa Remote on screen"))
        let manual = app.buttons["manualSetupButton"]
        if !manual.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        manual.tap()
        XCTAssertTrue(
            app.staticTexts[
                "Enter your TV's private address from its network settings. Choose Allow when the TV asks to approve Hafa Remote."
            ].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["manualTVBrandPicker"].exists)
        XCTAssertFalse(app.staticTexts["Samsung"].exists)
        XCTAssertFalse(app.switches["manualVizioLegacyConnection"].exists)
    }

    @MainActor
    func testMixedSavedRecordsRestoreOnlySamsungAndPreservePendingExperimentalRemoval() throws {
        let app = launch("-ui-testing-public-mixed")
        let witness = app.staticTexts["publicPreservationWitness"]
        XCTAssertTrue(witness.waitForExistence(timeout: 5))
        let expected = NSPredicate(format: "label == %@", "Saved: 3 · Connections: 1 · Removals: 0")
        expectation(for: expected, evaluatedWith: witness)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["myTVsButton"].exists)
        app.buttons["myTVsButton"].tap()
        XCTAssertFalse(app.staticTexts["Synthetic Sony Study TV"].exists)
        XCTAssertFalse(app.staticTexts["Synthetic Vizio Test TV"].exists)
        XCTAssertTrue(app.staticTexts["Synthetic Living TV"].exists)
    }

    @MainActor
    func testExperimentalOnlyRecordsLeavePublicAppUnpairedWithoutCleanup() throws {
        let app = launch("-ui-testing-public-experimental")
        let witness = app.staticTexts["publicPreservationWitness"]
        XCTAssertTrue(witness.waitForExistence(timeout: 5))
        let expected = NSPredicate(format: "label == %@", "Saved: 2 · Connections: 0 · Removals: 0")
        expectation(for: expected, evaluatedWith: witness)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["addTVButton"].exists)
        XCTAssertFalse(app.buttons["myTVsButton"].exists)
    }

    @MainActor
    func testExperimentalLaunchArgumentsCannotEnableAnExperimentalPublicScene() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-in-memory-store", "-ui-testing-discovery-empty", "-ui-testing-sony-pairing",
            "-ui-testing-conveniences", "-ui-testing-saved-sony-alias",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["addTVButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["sonyPairingCodeField"].exists)
        XCTAssertFalse(app.textFields["vizioPairingCodeField"].exists)
        XCTAssertFalse(app.buttons["remoteMoreControls"].exists)
    }

    @MainActor
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-in-memory-store", mode]
        app.launch()
        return app
    }
}
