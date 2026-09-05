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
        let wakeRecorded = expectation(
            for: NSPredicate(format: "label == %@", "wake"),
            evaluatedWith: commandOutput
        )
        wait(for: [wakeRecorded], timeout: 2)

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
}
