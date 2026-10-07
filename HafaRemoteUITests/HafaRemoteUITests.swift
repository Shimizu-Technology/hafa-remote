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

    /// Help is available before pairing and explains a wired TV on the home network.
    @MainActor
    func testFirstLaunchHelpExplainsLocalNetworkAndPairing() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-discovery-result")
        app.launch()

        let help = app.buttons["homeHelpButton"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        XCTAssertTrue(help.isHittable)
        help.tap()
        XCTAssertTrue(app.navigationBars["Help & About"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts[
                "Connect this iPhone to home Wi-Fi. Your TV can use Wi-Fi or Ethernet on the same network."
            ].exists
        )
        let sonyGuidance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Enter the six-character code shown on the TV.")
        ).firstMatch
        for _ in 0..<4 where !sonyGuidance.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sonyGuidance.waitForExistence(timeout: 2))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["addTVButton"].isHittable)
        app.buttons["addTVButton"].tap()
        let setupHelp = app.buttons["setupHelpButton"]
        XCTAssertTrue(setupHelp.waitForExistence(timeout: 2))
        setupHelp.tap()
        XCTAssertTrue(app.navigationBars["Help & About"].waitForExistence(timeout: 2))
    }

    /// The distinct playback controls dispatch independent commands without inferred playback state.
    @MainActor
    func testSeparatePlayAndPauseSendTheirOwnCommands() throws {
        let app = launchRemoteHarness()
        for command in ["play", "pause"] {
            let button = app.buttons["remote-\(command)"]
            XCTAssertTrue(button.waitForExistence(timeout: 2))
            for _ in 0..<6 where !button.isHittable {
                app.swipeUp()
            }
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            button.tap()
            let sent = expectation(
                for: NSPredicate(format: "label == %@", command),
                evaluatedWith: app.staticTexts["lastRemoteCommand"]
            )
            wait(for: [sent], timeout: 2)
        }
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

    /// Persisted discovery aliases must carry authenticated identity into deliberate saved-TV repair.
    @MainActor
    func testUniqueSavedSonyAliasRequiresScopedManagementAfterRejection() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-saved-sony-alias")
        app.launch()
        let candidate = app.buttons["discoveredTVButton"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        candidate.tap()
        assertSavedSonyManagement(app, expectedIdentity: "synthetic-authenticated-sony-a")
        XCTAssertEqual(app.staticTexts["sonyAssociationConnectionAttempts"].label, "1")
    }

    /// A collision cannot select or pair implicitly; a deliberate choice retains that record's identity.
    @MainActor
    func testCollidingSavedSonyAliasesRequireExplicitChoiceAndCancelDoesNotPair() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-colliding-sony-alias")
        app.launch()
        let candidate = app.buttons["discoveredTVButton"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        candidate.tap()
        let study = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Synthetic Study TV")
        ).firstMatch
        let den = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Synthetic Den TV")
        ).firstMatch
        XCTAssertTrue(study.waitForExistence(timeout: 2))
        XCTAssertTrue(den.exists)
        let sheetCancel = app.sheets.buttons["Cancel"].firstMatch
        if sheetCancel.exists && sheetCancel.isHittable {
            sheetCancel.tap()
        } else {
            // iOS 26 presents a popover with outside-tap dismissal instead of a Cancel row.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
        XCTAssertTrue(study.waitForNonExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["sonyAssociationConnectionAttempts"].label, "0")
        XCTAssertEqual(app.staticTexts["sonyAssociationExpectedIdentity"].label, "none")
        XCTAssertFalse(app.staticTexts["savedTVManagementRecoveryMessage"].exists)

        candidate.tap()
        XCTAssertTrue(study.waitForExistence(timeout: 2))
        study.tap()
        assertSavedSonyManagement(app, expectedIdentity: "synthetic-authenticated-sony-b")
        XCTAssertEqual(app.staticTexts["sonyAssociationConnectionAttempts"].label, "1")
    }

    /// The same real Sony rejection error remains a fresh-pair denial without saved identity.
    @MainActor
    func testFreshSonyRejectionRetainsManualDiscoveryRecovery() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-fresh-sony-rejection")
        app.launch()
        let candidate = app.buttons["discoveredTVButton"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        candidate.tap()
        let error = app.staticTexts["setupErrorMessage"]
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertTrue(error.label.contains("Sony pairing code was not accepted"))
        XCTAssertTrue(app.buttons["manualSetupButton"].exists)
        XCTAssertFalse(app.staticTexts["savedTVManagementRecoveryMessage"].exists)
        XCTAssertEqual(app.staticTexts["sonyAssociationExpectedIdentity"].label, "none")
        XCTAssertEqual(app.staticTexts["sonyAssociationConnectionAttempts"].label, "1")
        XCTAssertEqual(app.staticTexts["sonyAssociationAddressBasedAttempts"].label, "0")
        XCTAssertEqual(app.staticTexts["sonyAssociationForgetAttempts"].label, "0")
    }

    @MainActor
    private func assertSavedSonyManagement(_ app: XCUIApplication, expectedIdentity: String) {
        let instruction = app.staticTexts["savedTVManagementRecoveryMessage"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 3))
        XCTAssertTrue(instruction.label.contains("open My TVs"))
        XCTAssertTrue(instruction.label.contains("forget only this TV"))
        XCTAssertTrue(app.buttons["closeSetupForSavedTVManagement"].exists)
        XCTAssertEqual(app.staticTexts["sonyAssociationExpectedIdentity"].label, expectedIdentity)
        XCTAssertEqual(app.staticTexts["sonyAssociationAddressBasedAttempts"].label, "0")
        XCTAssertEqual(app.staticTexts["sonyAssociationForgetAttempts"].label, "0")
        XCTAssertFalse(app.buttons["manualSetupButton"].exists)
        XCTAssertFalse(app.buttons["forgetPairingButton"].exists)
        XCTAssertFalse(app.textFields["tvIPAddressField"].exists)
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
        waitForPairingEntry(codeField, value: "A1B2C3", submit: submit)
        submit.tap()

        let connectionStatus = app.staticTexts["remoteConnectionStatus"]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(connectionStatus.label, "Connected • TV power unknown")
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
        waitForPairingEntry(codeField, value: "1234", submit: submit)
        submit.tap()

        let connectionStatus = app.staticTexts["remoteConnectionStatus"]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(connectionStatus.label, "Connected • TV power unknown")
        XCTAssertFalse(app.buttons["remote-keyboard"].exists)
    }

    /// Repairing a rejected saved Vizio pairing preserves its brand-specific PIN flow.
    @MainActor
    func testVizioSavedPairingRepairPreservesPINFlow() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-vizio-pairing-repair")
        app.launch()

        let forget = app.buttons["forgetPairingButton"]
        for _ in 0..<6 where !forget.exists || !forget.isHittable {
            panSetupGutter(in: app, upward: true)
        }
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        XCTAssertTrue(forget.isHittable)
        XCTAssertGreaterThanOrEqual(forget.frame.height, 44)
        XCTAssertGreaterThanOrEqual(forget.frame.width, 44)
        forget.tap()
        XCTAssertTrue(forget.waitForNonExistence(timeout: 3))

        let codeField = app.textFields["vizioPairingCodeField"]
        for _ in 0..<6 where !codeField.isHittable {
            panSetupGutter(in: app, upward: false)
        }
        XCTAssertTrue(codeField.waitForExistence(timeout: 3))
        XCTAssertTrue(codeField.isHittable)
        codeField.tap()
        codeField.typeText("0000")

        let submit = app.buttons["submitVizioPairingCodeButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 2))
        waitForPairingEntry(codeField, value: "0000", submit: submit)
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
        expectation(
            for: NSPredicate(format: "label == 'Connected • TV power unknown'"), evaluatedWith: status)
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
        expectation(
            for: NSPredicate(format: "label == 'Connected • TV power unknown'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
    }

    /// Returning from another app reconnects the saved TV without user intervention.
    @MainActor
    func testSavedTVReconnectsAfterBackgroundReturn() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-saved-tvs")
        app.launchArguments.append("-ui-testing-saved-tv-lifecycle")
        app.launch()

        let status = app.staticTexts["remoteConnectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "label == 'Connected • TV power unknown'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        let completedConnections = app.staticTexts["savedTVCompletedConnections"]
        XCTAssertTrue(completedConnections.waitForExistence(timeout: 2))
        XCTAssertEqual(completedConnections.label, "1")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 2)
                || app.wait(for: .runningBackgroundSuspended, timeout: 3),
            "Home must background the app, whether iOS has suspended it yet or not"
        )
        app.activate()

        let recovery = app.descendants(matching: .any)["automaticReconnectStatus"]
        // activate() can wait for UI idleness until a quick reconnect finishes.
        // Verify recovery completes and control returns, rather than requiring
        // a transient banner to remain visible after activation.
        XCTAssertTrue(recovery.waitForNonExistence(timeout: 10))
        expectation(
            for: NSPredicate(format: "label == '2'"),
            evaluatedWith: completedConnections
        )
        waitForExpectations(timeout: 10)
        expectation(
            for: NSPredicate(format: "label == 'Connected • TV power unknown'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        let select = app.buttons["remote-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 2))
        XCTAssertTrue(select.isEnabled)
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
        XCTAssertTrue(app.staticTexts["Connected • TV power unknown"].waitForExistence(timeout: 2))
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
        expectation(
            for: NSPredicate(format: "label == 'Connected • TV power unknown'"), evaluatedWith: status)
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

    /// Control Center setup is discoverable and explains the privacy boundary.
    @MainActor
    func testMyTVsExplainsControlCenterAccess() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-saved-tvs")
        app.launch()

        XCTAssertTrue(app.buttons["myTVsButton"].waitForExistence(timeout: 5))
        app.buttons["myTVsButton"].tap()
        let help = app.buttons["controlCenterHelpButton"]
        for _ in 0..<3 where !help.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(help.waitForExistence(timeout: 2))
        help.tap()

        XCTAssertTrue(app.navigationBars["Help & About"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["Step 1. Open Control Center, then touch and hold an empty area."].exists)
        let privacyBoundary = app.staticTexts["The control only opens Hafa Remote."]
        for _ in 0..<3 where !privacyBoundary.exists {
            app.swipeUp()
        }
        XCTAssertTrue(privacyBoundary.waitForExistence(timeout: 2))
        let noAccount = app.staticTexts["No account, cloud sync, ads, tracking, or subscription."]
        for _ in 0..<3 where !noAccount.exists {
            app.swipeUp()
        }
        XCTAssertTrue(noAccount.waitForExistence(timeout: 2))
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
                XCTAssertTrue(
                    ["Connected", "Connected • TV power unknown"].contains(existingConnection.label))
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
            XCTAssertTrue(["Connected", "Connected • TV power unknown"].contains(connectionStatus.label))

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
            XCTAssertTrue(["Connected", "Connected • TV power unknown"].contains(restoredStatus.label))
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
            for _ in 0..<6 where !button.isHittable {
                app.swipeDown()
            }
            XCTAssertTrue(button.isHittable, "Unreachable \(command) control")
            XCTAssertTrue(button.isEnabled, "Disabled \(command) control")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "Narrow \(command) target")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "Short \(command) target")
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
        let app = makeApplication(contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        app.launchArguments.append("-ui-testing-remote")
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

    /// Large-text volume actions form an aligned column and keep their semantic dispatch.
    @MainActor
    func testLargestDynamicTypeVolumeActionsRemainAlignedAndReachable() throws {
        let app = makeApplication(contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        app.launchArguments.append("-ui-testing-remote")
        app.launch()
        XCTAssertTrue(app.staticTexts["currentDynamicTypeSize"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["currentDynamicTypeSize"].label, "accessibility5")
        var columnX: CGFloat?
        for command in ["volumeDown", "mute", "volumeUp"] {
            let button = app.buttons["remote-\(command)"]
            XCTAssertTrue(button.waitForExistence(timeout: 2))
            for _ in 0..<12 {
                let top = app.navigationBars.firstMatch.frame.maxY + 8
                let bottom = app.frame.maxY - 8
                if button.isHittable && button.frame.minY >= top && button.frame.maxY <= bottom {
                    break
                }
                // Short bidirectional pans avoid skipping a tall accessibility row.
                let desiredCenter = (top + bottom) / 2
                let movement = min(180, max(-180, button.frame.midY - desiredCenter))
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6))
                let end = app.coordinate(
                    withNormalizedOffset: CGVector(
                        dx: 0.1, dy: 0.6 - movement / app.frame.height
                    ))
                start.press(
                    forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
            }
            if !button.isHittable {
                let blocked = XCTAttachment(screenshot: app.screenshot())
                blocked.name = "Unreachable large-type \(command)"
                blocked.lifetime = .keepAlways
                add(blocked)
            }
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            if let columnX {
                XCTAssertEqual(button.frame.midX, columnX, accuracy: 1)
            } else {
                columnX = button.frame.midX
            }
            button.tap()
            let dispatched = expectation(
                for: NSPredicate(format: "label == %@", command),
                evaluatedWith: app.staticTexts["lastRemoteCommand"]
            )
            wait(for: [dispatched], timeout: 2)
        }
        // Place the complete group below the native bar for inspectable visual evidence.
        let down = app.buttons["remote-volumeDown"]
        let up = app.buttons["remote-volumeUp"]
        // An offscreen heading can have a clipped frame; anchor on the actual action target.
        let desiredDownY = app.navigationBars.firstMatch.frame.maxY + down.frame.height + 24
        let delta = desiredDownY - down.frame.minY
        if abs(delta) > 1 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            let endY = min(0.9, max(0.1, 0.5 + delta / app.frame.height))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        for _ in 0..<4 where down.frame.minY < app.navigationBars.firstMatch.frame.maxY + 8 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.52))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        XCTAssertTrue(down.isHittable)
        XCTAssertTrue(up.isHittable)
        XCTAssertGreaterThanOrEqual(down.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(up.frame.maxY, app.frame.maxY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Largest Dynamic Type aligned volume rows"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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

    /// Pairing recovery tells the user to approve the connection on the TV.
    @MainActor
    func testPairingRemoteShowsTVApprovalInstructions() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-remote-pairing")
        app.launch()

        let approval = app.descendants(matching: .any)["pairingApprovalStatus"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5))
        XCTAssertTrue(approval.label.contains("Approve Hafa Remote on your TV"))
        XCTAssertFalse(app.buttons["retryConnectionButton"].exists)
        let select = app.buttons["remote-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 2))
        XCTAssertFalse(select.isEnabled)
    }

    @MainActor
    func testConnectedStandbyOffersPowerOn() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-remote-standby")
        app.launch()
        let power = app.buttons["remote-powerOn"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        XCTAssertTrue(power.isEnabled)
        XCTAssertFalse(app.buttons["remote-powerOff"].exists)
        XCTAssertFalse(app.buttons["remote-select"].isEnabled)
        XCTAssertTrue(app.staticTexts["remoteConnectionStatus"].label.contains("standby"))
        power.tap()
        let delivered = expectation(
            for: NSPredicate(format: "label == %@", "powerOn"),
            evaluatedWith: app.staticTexts["lastRemoteCommand"])
        wait(for: [delivered], timeout: 2)
    }

    @MainActor
    func testAutomaticReconnectKeepsWakeAndManualRecoveryAvailable() throws {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-remote-reconnecting")
        app.launch()
        let power = app.buttons["remote-powerOn"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        XCTAssertTrue(power.isEnabled)
        XCTAssertTrue(app.buttons["retryConnectionButton"].isEnabled)
        XCTAssertTrue(app.buttons["remoteTVSetupButton"].isEnabled)
        power.tap()
        let delivered = expectation(
            for: NSPredicate(format: "label == %@", "powerOn"),
            evaluatedWith: app.staticTexts["lastRemoteCommand"])
        wait(for: [delivered], timeout: 2)
    }

    @MainActor
    func testOfflineDemoIsAvailableBeforePairing() throws {
        let app = makeApplication()
        app.launch()
        app.buttons["homeSupportButton"].tap()
        let demo = app.buttons["openOfflineDemoButton"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.tap()
        XCTAssertTrue(app.staticTexts["offlineDemoLabel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["submitSonyPairingCodeButton"].exists)
        XCTAssertFalse(app.buttons["submitVizioPairingCodeButton"].exists)
        let volume = app.staticTexts["demoVolumeState"]
        XCTAssertTrue(volume.label.contains("20"))
        let louder = app.buttons["demo-volumeUp"]
        if !louder.isHittable { app.swipeUp() }
        louder.tap()
        XCTAssertTrue(volume.label.contains("21"))
    }

    @MainActor
    func testDiagnosticsAreOptInAndPreviewableBeforeSharing() throws {
        let app = makeApplication()
        app.launch()
        app.buttons["homeSupportButton"].tap()
        let diagnostics = app.buttons["openDiagnosticsButton"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        let toggle = app.switches["diagnosticsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["previewDiagnosticsButton"].tap()
        let preview = app.staticTexts["diagnosticsReportPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("No events recorded"))
        XCTAssertTrue(app.buttons["shareDiagnosticsButton"].exists)
    }

    @MainActor
    private func launchRemoteHarness() -> XCUIApplication {
        let app = makeApplication()
        app.launchArguments.append("-ui-testing-remote")
        app.launch()
        return app
    }

    @MainActor
    private func makeApplication(contentSizeCategory: String = "UICTContentSizeCategoryL") -> XCUIApplication
    {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-in-memory-store", "-UIPreferredContentSizeCategoryName",
            contentSizeCategory,
        ]
        return app
    }

    /// Scroll from the form gutter, away from the brand menu and destructive actions.
    @MainActor
    private func panSetupGutter(in app: XCUIApplication, upward: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: upward ? 0.7 : 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: upward ? 0.4 : 0.6))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// Waits for the validated text and its corresponding asynchronous accessibility state.
    @MainActor
    private func waitForPairingEntry(_ field: XCUIElement, value: String, submit: XCUIElement) {
        let enteredValue = expectation(
            for: NSPredicate(format: "value == %@", value), evaluatedWith: field)
        let enabledSubmit = expectation(
            for: NSPredicate(format: "enabled == true"), evaluatedWith: submit)
        wait(for: [enteredValue, enabledSubmit], timeout: 2)
        XCTAssertEqual(field.value as? String, value)
        XCTAssertTrue(submit.isEnabled)
    }

    /// Replaces a text field's full value through the same edit menu available to users.
    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        let app = XCUIApplication()
        field.tap()
        field.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 2))
        selectAll.tap()
        // Typing through the field can refocus it and collapse the selection on
        // newer iOS runtimes. Send keys to the already-focused application.
        app.typeText(value)
        let replaced = expectation(
            for: NSPredicate(format: "value == %@", value),
            evaluatedWith: field
        )
        wait(for: [replaced], timeout: 5)
    }
}
