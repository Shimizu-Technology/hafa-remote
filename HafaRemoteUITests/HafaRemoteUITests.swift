import XCTest

/// End-to-end checks for the first-launch Hafa Remote experience.
final class HafaRemoteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Verifies that the primary empty-state action remains discoverable and opens setup.
    @MainActor
    func testEmptyStateOpensTVSetup() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-discovery-result")
        app.launch()

        XCTAssertTrue(app.navigationBars["Hafa Remote"].waitForExistence(timeout: 5))

        let addButton = app.buttons["addTVButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        XCTAssertTrue(addButton.isHittable)
        addButton.tap()

        XCTAssertTrue(app.navigationBars["Add TV"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.textFields["tvIPAddressField"].exists)

        let discoveredTV = app.buttons["discoveredTVButton"]
        XCTAssertTrue(discoveredTV.waitForExistence(timeout: 2))
        XCTAssertTrue(discoveredTV.isHittable)
        XCTAssertTrue(discoveredTV.label.contains("Living Room TV"))

        let manualSetup = app.buttons["manualSetupButton"]
        XCTAssertTrue(manualSetup.waitForExistence(timeout: 2))
        manualSetup.tap()
        let addressField = app.textFields["tvIPAddressField"]
        for _ in 0..<3 where !addressField.exists {
            app.swipeUp()
        }
        XCTAssertTrue(addressField.waitForExistence(timeout: 2))

        let connectButton = app.buttons["connectToTVButton"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 2))
        XCTAssertFalse(connectButton.isEnabled)
    }

    /// No-result discovery remains understandable and preserves a manual recovery path.
    @MainActor
    func testDiscoveryNoResultsOffersRetryAndManualFallback() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-discovery-retry")
        app.launch()

        let addButton = app.buttons["addTVButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        XCTAssertTrue(app.staticTexts["No supported TVs found"].waitForExistence(timeout: 2))
        let scanAgain = app.buttons["scanAgainButton"]
        XCTAssertTrue(scanAgain.waitForExistence(timeout: 2))
        XCTAssertTrue(scanAgain.isHittable)
        scanAgain.tap()

        let discoveredTV = app.buttons["discoveredTVButton"]
        XCTAssertTrue(discoveredTV.waitForExistence(timeout: 2))
        XCTAssertTrue(discoveredTV.label.contains("Living Room TV"))

        let manualSetup = app.buttons["manualSetupButton"]
        XCTAssertTrue(manualSetup.waitForExistence(timeout: 2))
        manualSetup.tap()
        let addressField = app.textFields["tvIPAddressField"]
        for _ in 0..<3 where !addressField.exists {
            app.swipeUp()
        }
        XCTAssertTrue(addressField.waitForExistence(timeout: 2))
    }

    /// Sony discovery stays address-free and uses the short code shown on the TV.
    @MainActor
    func testSonyPairingCodeFlow() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-sony-pairing")
        app.launch()

        let addButton = app.buttons["addTVButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let discoveredTV = app.buttons["discoveredTVButton"]
        XCTAssertTrue(discoveredTV.waitForExistence(timeout: 2))
        XCTAssertTrue(discoveredTV.label.contains("Sony"))
        discoveredTV.tap()

        let codeField = app.textFields["sonyPairingCodeField"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 2))
        let submit = app.buttons["submitSonyPairingCodeButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 2))
        XCTAssertFalse(submit.isEnabled)

        codeField.tap()
        codeField.typeText("A1B2C3")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        let connectionStatus = app.staticTexts["remoteConnectionStatus"]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(connectionStatus.label, "Connected")
        XCTAssertFalse(app.buttons["remote-keyboard"].exists)
    }

    /// Vizio discovery stays address-free and uses the four-digit PIN shown on the TV.
    @MainActor
    func testVizioPairingPINFlow() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-vizio-pairing")
        app.launch()

        let addButton = app.buttons["addTVButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let discoveredTV = app.buttons["discoveredTVButton"]
        XCTAssertTrue(discoveredTV.waitForExistence(timeout: 2))
        XCTAssertTrue(discoveredTV.label.contains("Vizio"))
        discoveredTV.tap()

        let codeField = app.textFields["vizioPairingCodeField"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 2))
        let submit = app.buttons["submitVizioPairingCodeButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 2))
        XCTAssertFalse(submit.isEnabled)

        codeField.tap()
        codeField.typeText("1234")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        let connectionStatus = app.staticTexts["remoteConnectionStatus"]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(connectionStatus.label, "Connected")
        XCTAssertFalse(app.buttons["remote-keyboard"].exists)
    }

    /// Repairing a rejected saved Vizio pairing preserves its brand-specific PIN flow.
    @MainActor
    func testVizioSavedPairingRepairPreservesPINFlow() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-vizio-pairing-repair")
        app.launch()

        let forget = app.buttons["forgetPairingButton"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        for _ in 0..<3 where !forget.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(forget.isHittable)
        forget.tap()
        XCTAssertTrue(forget.waitForNonExistence(timeout: 3))

        let codeField = app.textFields["vizioPairingCodeField"]
        for _ in 0..<3 where !codeField.exists {
            app.swipeDown()
        }
        XCTAssertTrue(codeField.waitForExistence(timeout: 3))
        codeField.tap()
        codeField.typeText("0000")

        let submit = app.buttons["submitVizioPairingCodeButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 2))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        let error = app.staticTexts["setupErrorMessage"]
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertTrue(error.label.contains("Vizio PIN was not accepted"))
    }

    /// Saved televisions can be switched directly from My TVs without scanning again.
    @MainActor
    func testMyTVsSwitchesTheVisibleAndConnectedTarget() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-saved-tvs")
        app.launch()

        let tvName = app.staticTexts["remoteTVName"]
        XCTAssertTrue(tvName.waitForExistence(timeout: 5))
        XCTAssertEqual(tvName.label, "Living Room TV")
        let status = app.staticTexts["remoteConnectionStatus"]
        expectation(for: NSPredicate(format: "label == 'Connected'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)

        let myTVs = app.buttons["myTVsButton"]
        XCTAssertTrue(myTVs.waitForExistence(timeout: 2))
        myTVs.tap()
        XCTAssertTrue(app.navigationBars["My TVs"].waitForExistence(timeout: 2))

        let sideDoorTV = app.buttons["myTVRow-sony:fixture-sony"]
        XCTAssertTrue(sideDoorTV.waitForExistence(timeout: 2))
        sideDoorTV.tap()

        expectation(for: NSPredicate(format: "label == 'Connecting'"), evaluatedWith: status)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(app.staticTexts["Side Door TV"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == 'Connected'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
    }

    /// TV names and rooms remain editable from the visible saved-TV library.
    @MainActor
    func testMyTVsEditsNameAndRoom() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-saved-tvs")
        app.launch()

        XCTAssertTrue(app.buttons["myTVsButton"].waitForExistence(timeout: 5))
        app.buttons["myTVsButton"].tap()
        let manage = app.buttons["manageMyTV-samsung:fixture-samsung"]
        XCTAssertTrue(manage.waitForExistence(timeout: 2))
        manage.tap()
        let edit = app.buttons["Edit Name & Room"]
        XCTAssertTrue(edit.waitForExistence(timeout: 2))
        edit.tap()

        let name = app.textFields["savedTVNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        replaceText(in: name, with: "Den TV")
        let room = app.textFields["savedTVRoomField"]
        replaceText(in: room, with: "Den")
        app.buttons["saveTVEditsButton"].tap()

        XCTAssertTrue(app.staticTexts["Den TV"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Den · Samsung · Q70AA"].exists)
    }

    /// Forget is deliberate and removes the selected local library row.
    @MainActor
    func testMyTVsForgetsTVAfterConfirmation() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-saved-tvs")
        app.launch()

        XCTAssertTrue(app.buttons["myTVsButton"].waitForExistence(timeout: 5))
        app.buttons["myTVsButton"].tap()
        let manage = app.buttons["manageMyTV-sony:fixture-sony"]
        XCTAssertTrue(manage.waitForExistence(timeout: 2))
        manage.tap()
        app.buttons["Forget TV"].tap()
        XCTAssertTrue(app.staticTexts["Forget Side Door TV?"].waitForExistence(timeout: 2))
        app.buttons["Forget"].tap()

        let forgottenRow = app.buttons["myTVRow-sony:fixture-sony"]
        let removed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: forgottenRow
        )
        wait(for: [removed], timeout: 5)
        XCTAssertTrue(app.buttons["myTVRow-samsung:fixture-samsung"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 2))
    }

    /// Forgetting the active TV skips malformed records and connects a usable fallback.
    @MainActor
    func testMyTVsForgetSelectedSkipsMalformedFallback() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-saved-tvs")
        app.launch()

        XCTAssertTrue(app.buttons["myTVsButton"].waitForExistence(timeout: 5))
        app.buttons["myTVsButton"].tap()
        let manage = app.buttons["manageMyTV-samsung:fixture-samsung"]
        XCTAssertTrue(manage.waitForExistence(timeout: 2))
        manage.tap()
        app.buttons["Forget TV"].tap()
        app.buttons["Forget"].tap()

        let sonyRow = app.buttons["myTVRow-sony:fixture-sony"]
        XCTAssertTrue(sonyRow.waitForExistence(timeout: 2))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Side Door TV"].waitForExistence(timeout: 2))
        let status = app.staticTexts["remoteConnectionStatus"]
        expectation(for: NSPredicate(format: "label == 'Connected'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
    }

    /// Add TV remains a prominent action from the saved-TV library.
    @MainActor
    func testMyTVsOpensAddTV() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-saved-tvs")
        app.launch()

        XCTAssertTrue(app.buttons["myTVsButton"].waitForExistence(timeout: 5))
        app.buttons["myTVsButton"].tap()
        let addTV = app.buttons["addTVFromLibraryButton"]
        XCTAssertTrue(addTV.waitForExistence(timeout: 2))
        addTV.tap()

        XCTAssertTrue(app.navigationBars["Add TV"].waitForExistence(timeout: 3))
    }

    /// A malformed saved endpoint remains visible and manageable instead of stranding the user.
    @MainActor
    func testMyTVsRemainsAvailableForMalformedSavedTV() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-malformed-saved-tv")
        app.launch()

        let myTVs = app.buttons["myTVsButton"]
        XCTAssertTrue(myTVs.waitForExistence(timeout: 5))
        XCTAssertTrue(myTVs.isHittable)
        myTVs.tap()

        XCTAssertTrue(app.staticTexts["Needs Setup"].waitForExistence(timeout: 2))
        let manage = app.buttons["manageMyTV-samsung:fixture-malformed"]
        XCTAssertTrue(manage.exists)
        manage.tap()
        app.buttons["Forget TV"].tap()
        app.buttons["Forget"].tap()

        let malformedRow = app.buttons["myTVRow-samsung:fixture-malformed"]
        let removed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: malformedRow
        )
        wait(for: [removed], timeout: 5)
    }

    /// Runs separately from the deterministic gate against the powered-on household TV.
    @MainActor
    func testHardwareDiscoveryFindsSamsungTV() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Requires an iPhone and a powered-on Samsung TV on the same Wi-Fi network.")
        #else
            let app = XCUIApplication()
            let permissionMonitor = addUIInterruptionMonitor(
                withDescription: "Local Network permission"
            ) { alert in
                let allowButton = alert.buttons["Allow"]
                guard allowButton.exists else { return false }
                allowButton.tap()
                return true
            }
            defer { removeUIInterruptionMonitor(permissionMonitor) }

            app.launch()

            let addButton = app.buttons["addTVButton"]
            if addButton.waitForExistence(timeout: 5) {
                addButton.tap()
            } else {
                let existingConnection = app.staticTexts["remoteConnectionStatus"]
                XCTAssertTrue(
                    existingConnection.waitForExistence(timeout: 10),
                    "Expected either first-run setup or an already paired Q70AA."
                )
                XCTAssertEqual(existingConnection.label, "Connected")
                let changeTV = app.buttons["changeTVButton"]
                XCTAssertTrue(changeTV.waitForExistence(timeout: 5))
                changeTV.tap()
            }

            // XCTest invokes interruption monitors on the next interaction if iOS presents a prompt.
            app.navigationBars["Add TV"].tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let localNetworkAllow = springboard.buttons["Allow"].firstMatch
            if localNetworkAllow.waitForExistence(timeout: 3) {
                localNetworkAllow.tap()
            }

            let discoveredTV = app.buttons["discoveredTVButton"]
            XCTAssertTrue(
                discoveredTV.waitForExistence(timeout: 15),
                "Expected a verified Samsung TV advertised over the local network."
            )
            XCTAssertTrue(discoveredTV.isHittable)
            XCTAssertTrue(
                discoveredTV.label.localizedCaseInsensitiveContains("Q70AA"),
                "Expected the household Q70AA model to be recognizable in the discovery row."
            )

            discoveredTV.tap()

            let connectionStatus = app.staticTexts["remoteConnectionStatus"]
            XCTAssertTrue(
                connectionStatus.waitForExistence(timeout: 60),
                "Expected physical approval to open the connected remote."
            )
            XCTAssertEqual(connectionStatus.label, "Connected")

            let select = app.buttons["remote-select"]
            XCTAssertTrue(select.waitForExistence(timeout: 5))
            XCTAssertTrue(select.isHittable)
            XCTAssertTrue(select.isEnabled)
            select.tap()

            app.terminate()
            app.launch()

            let restoredStatus = app.staticTexts["remoteConnectionStatus"]
            XCTAssertTrue(
                restoredStatus.waitForExistence(timeout: 20),
                "Expected the saved pairing to restore after relaunch."
            )
            XCTAssertEqual(restoredStatus.label, "Connected")
        #endif
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

    /// Confirmed power-off waits for the dedicated action before reporting delivery.
    @MainActor
    func testConfirmedPowerOffUsesDedicatedAction() throws {
        let app = launchRemoteHarness()
        let power = app.buttons["remote-powerOff"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        power.tap()
        app.buttons["Turn Off"].tap()

        let commandOutput = app.staticTexts["lastRemoteCommand"]
        let powerOffRecorded = expectation(
            for: NSPredicate(format: "label == %@", "powerOff"),
            evaluatedWith: commandOutput
        )
        wait(for: [powerOffRecorded], timeout: 2)
    }

    /// A rejected power command stays visible instead of silently pretending the TV turned off.
    @MainActor
    func testPowerOffFailureIsVisible() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-remote-power-off-failure")
        app.launch()

        let power = app.buttons["remote-powerOff"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        power.tap()
        app.buttons["Turn Off"].tap()

        XCTAssertTrue(app.staticTexts["Couldn’t Send Power Off"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Hafa Remote could not deliver power off."].exists)
        XCTAssertEqual(app.staticTexts["lastRemoteCommand"].label, "none")
    }

    /// The scrollable remote must remain usable at the largest accessibility text size.
    @MainActor
    func testRemoteSupportsLargestDynamicType() throws {
        let app = makeApplication()
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
        XCTAssertTrue(keyboard.isEnabled)
    }

    /// Text entry uses the native keyboard and never claims the TV inserted the text.
    @MainActor
    func testKeyboardSendsValidatedTextWithHonestResult() throws {
        let app = launchRemoteHarness()
        let keyboard = app.buttons["remote-keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
        for _ in 0..<6 where !keyboard.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(keyboard.isHittable)
        keyboard.tap()

        let textField = app.textFields["remoteTextField"]
        XCTAssertTrue(textField.waitForExistence(timeout: 2))
        XCTAssertTrue(textField.isHittable)
        textField.tap()
        textField.typeText("Hafa")
        XCTAssertEqual(textField.value as? String, "Hafa")

        let send = app.buttons["sendRemoteTextButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let result = app.staticTexts["remoteTextResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 2))
        XCTAssertTrue(result.label.contains("If nothing appeared"))
        XCTAssertEqual(app.staticTexts["lastRemoteCommand"].label, "text:4")
    }

    /// Offline state disables commands while keeping wake and recovery obvious and functional.
    @MainActor
    func testOfflineRemoteOffersRecoveryWithoutSendingCommands() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-remote-offline")
        app.launch()

        let select = app.buttons["remote-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        XCTAssertFalse(select.isEnabled)
        let powerOn = app.buttons["remote-powerOn"]
        XCTAssertTrue(powerOn.waitForExistence(timeout: 2))
        XCTAssertTrue(powerOn.isEnabled)
        powerOn.tap()

        let commandOutput = app.staticTexts["lastRemoteCommand"]
        let powerOnRecorded = expectation(
            for: NSPredicate(format: "label == %@", "powerOn"),
            evaluatedWith: commandOutput
        )
        wait(for: [powerOnRecorded], timeout: 2)

        let keyboard = app.buttons["remote-keyboard"]
        for _ in 0..<6 where !keyboard.exists {
            app.swipeUp()
        }
        XCTAssertTrue(keyboard.exists)
        XCTAssertFalse(keyboard.isEnabled)

        let retry = app.buttons["retryConnectionButton"]
        XCTAssertTrue(retry.waitForExistence(timeout: 2))
        retry.tap()
        let retryRecorded = expectation(
            for: NSPredicate(format: "label == %@", "retry"),
            evaluatedWith: commandOutput
        )
        wait(for: [retryRecorded], timeout: 2)

        let tvSetup = app.buttons["remoteTVSetupButton"]
        XCTAssertTrue(tvSetup.isHittable)
        tvSetup.tap()
        XCTAssertEqual(app.staticTexts["lastRemoteCommand"].label, "setup")
    }

    @MainActor
    private func launchRemoteHarness() -> XCUIApplication {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-remote")
        app.launch()
        return app
    }

    @MainActor
    private func makeApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-in-memory-store")
        return app
    }

    /// Replaces a text field's full value through the same edit menu available to users.
    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        field.press(forDuration: 1)
        let selectAll = XCUIApplication().menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 2))
        selectAll.tap()
        field.typeText(value)
    }
}
