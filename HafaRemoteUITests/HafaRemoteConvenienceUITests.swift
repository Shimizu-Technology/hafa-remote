import XCTest

final class HafaRemoteConvenienceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSamsungSourceChannelGuideDigitsAndSentFeedback() {
        let app = launch()
        openMore(app)
        for command in ["inputSource", "channelUp", "guide", "digit7"] {
            let button = app.buttons["convenience-\(command)"]
            reveal(button, in: app)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            button.tap()
            assertTrace("command:\(command)", in: app)
        }
        let appButton = app.buttons["availableApp-Synthetic Video"]
        reveal(appButton, in: app)
        XCTAssertGreaterThanOrEqual(appButton.frame.height, 44)
        appButton.tap()
        assertTrace("request:launch:Synthetic Video", in: app)
        let result = app.staticTexts["convenienceResult"]
        reveal(result, in: app)
        XCTAssertEqual(result.label, "Request sent. Check the TV for the result.")
        XCTAssertFalse(app.staticTexts["App opened"].exists)
        attach(app, name: "Samsung-more-controls")
    }

    @MainActor
    func testSamsungFavoritesStayWithTheirTVAndStarDoesNotLaunch() {
        let app = launch()
        openMore(app)
        assertTrace("request:apps", in: app)
        let save = app.buttons["toggleFavorite-available-Synthetic Video"]
        reveal(save, in: app)
        save.tap()
        XCTAssertEqual(app.staticTexts["convenienceFixtureTrace"].label, "request:apps")
        reveal(app.buttons["favoriteApp-Synthetic Video"], in: app)
        backToRemote(app)
        app.buttons["switchConvenienceFixtureTV"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic Samsung B"].waitForExistence(timeout: 3))
        openMore(app)
        reveal(app.buttons["availableApp-Synthetic Video"], in: app)
        XCTAssertFalse(app.buttons["favoriteApp-Synthetic Video"].exists)
        backToRemote(app)
        app.buttons["switchConvenienceFixtureTV"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic Samsung A"].waitForExistence(timeout: 3))
        openMore(app)
        reveal(app.buttons["favoriteApp-Synthetic Video"], in: app)
        app.buttons["toggleFavorite-favorite-Synthetic Video"].tap()
        XCTAssertFalse(app.buttons["favoriteApp-Synthetic Video"].exists)
    }

    @MainActor
    func testVizioReturnedInputsCurrentAppAndUnsupportedControls() {
        let app = launch(brand: "vizio")
        XCTAssertFalse(app.buttons["remote-keyboard"].exists)
        openMore(app)
        assertTrace("request:inputs", in: app)
        app.buttons["convenienceInput-HDMI-1"].tap()
        assertTrace("request:input:HDMI-1", in: app)
        XCTAssertFalse(app.buttons["convenience-guide"].exists)
        XCTAssertFalse(app.buttons["convenience-digit1"].exists)
        XCTAssertFalse(app.switches["remoteKeyboardPreference"].exists)
        let currentApp = app.buttons["Save Current TV App"]
        reveal(currentApp, in: app)
        currentApp.tap()
        assertTrace("request:currentApp", in: app)
        let name = app.alerts["Name this favorite"].textFields["App name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.tap()
        name.typeText("Synthetic Family Video")
        app.alerts.buttons["Save"].tap()
        let favorite = app.buttons["favoriteApp-Synthetic Family Video"]
        reveal(favorite, in: app, direction: .down)
        favorite.tap()
        assertTrace("request:launch:Synthetic Family Video", in: app)
        let result = app.staticTexts["convenienceResult"]
        reveal(result, in: app)
        XCTAssertEqual(result.label, "Request sent. Check the TV for the result.")
        attach(app, name: "Vizio-inputs-and-saved-app")
    }

    @MainActor
    func testVizioSavedFavoriteWorksBeforeCurrentAppRead() {
        let app = launch(
            brand: "vizio",
            extra: [
                "-convenience-no-optional-features", "-convenience-restored-favorite",
            ])
        openMore(app)
        let favorite = app.buttons["favoriteApp-Synthetic Saved Video"]
        reveal(favorite, in: app)
        XCTAssertTrue(favorite.isEnabled)
        favorite.tap()
        assertTrace("request:launch:Synthetic Saved Video", in: app)
        XCTAssertFalse(app.staticTexts["App opened"].exists)
        backToRemote(app)
        let volume = app.buttons["remote-volumeUp"]
        reveal(volume, in: app, direction: .down)
        volume.tap()
        assertTrace("command:volumeUp", in: app)
    }

    @MainActor
    func testSonyConfiguredLinksKeyboardPreferenceAndFocusError() {
        let app = launch(brand: "sony")
        let keyboard = app.buttons["remote-keyboard"]
        reveal(keyboard, in: app)
        keyboard.tap()
        let input = app.textFields["remoteTextField"]
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        input.tap()
        input.typeText("Synthetic search")
        app.buttons["sendRemoteTextButton"].tap()
        XCTAssertTrue(app.staticTexts["remoteTextResult"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["remoteTextResult"].label.contains("Focus a text field"))
        app.buttons["Done"].tap()
        openMore(app)
        let netflix = app.buttons["availableApp-Netflix"]
        reveal(netflix, in: app)
        netflix.tap()
        assertTrace("request:launch:Netflix", in: app)
        let toggle = app.switches["remoteKeyboardPreference"]
        revealGestureSurface(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        assertTrace("request:keyboard:false", in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        backToRemote(app)
        XCTAssertFalse(app.buttons["remote-keyboard"].exists)
        openMore(app)
        revealGestureSurface(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        assertTrace("request:keyboard:true", in: app)
        backToRemote(app)
        XCTAssertTrue(app.buttons["remote-keyboard"].exists)
    }

    @MainActor
    func testSonyUnnegotiatedFeaturesStayAbsent() {
        let app = launch(brand: "sony", extra: ["-convenience-no-optional-features"])
        XCTAssertFalse(app.buttons["remote-keyboard"].exists)
        openMore(app)
        XCTAssertFalse(app.buttons["availableApp-Netflix"].exists)
        XCTAssertFalse(app.buttons["Refresh Apps"].exists)
        XCTAssertFalse(app.buttons["convenience-guide"].exists)
        XCTAssertFalse(app.buttons["convenience-digit0"].exists)
    }

    @MainActor
    func testButtonsSwipeFallbackAndLargeTextDarkControls() {
        let app = launch(
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL",
            extra: ["-convenience-dark", "-convenience-visible-trace"])
        let picker = app.segmentedControls["navigationModePicker"]
        reveal(picker, in: app)
        picker.buttons["Swipe"].tap()
        let swipe = app.otherElements["remoteSwipeControl"]
        revealGestureSurface(swipe, in: app)
        XCTAssertTrue(swipe.isHittable)
        let trace = app.staticTexts["convenienceFixtureTrace"]
        XCTAssertTrue(trace.waitForExistence(timeout: 2), "A live dispatch observer is required before input")
        XCTAssertNotEqual(trace.label, "command:right", "The gesture must create a new dispatch result")
        let baseline = XCTAttachment(
            string: "Before drag: trace=\(trace.label), frame=\(trace.frame), pad=\(swipe.frame)")
        baseline.name = "Live trace and gesture frames before input"
        baseline.lifetime = .keepAlways
        add(baseline)
        attach(app, name: "Dark-largest-text-swipe-surface")
        let from = swipe.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let to = swipe.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
        assertTrace("command:right", in: app)
        swipe.tap()
        assertTrace("command:select", in: app)
        reveal(picker, in: app)
        picker.buttons["Buttons"].tap()
        let up = app.buttons["remote-up"]
        reveal(up, in: app, direction: .down)
        up.tap()
        assertTrace("command:up", in: app)
        XCTAssertGreaterThanOrEqual(up.frame.width, 44)
        XCTAssertGreaterThanOrEqual(up.frame.height, 44)
        attach(app, name: "Dark-large-text-buttons-fallback")
    }

    /// Hittability includes partially visible surfaces; a drag needs its full path below the bar.
    @MainActor private func revealGestureSurface(_ element: XCUIElement, in app: XCUIApplication) {
        let top = app.navigationBars.firstMatch.frame.maxY + 16
        // Keep the whole control above the home indicator without reserving unused Form footer space.
        let bottom = app.frame.maxY - 64
        for _ in 0..<12 {
            // Form rows below the viewport may not have an accessibility element yet.
            guard element.exists else {
                panGutter(in: app, upward: true)
                continue
            }
            let frame = element.frame
            if element.isHittable, frame.minY >= top, frame.maxY <= bottom { break }
            let upward = frame.maxY > bottom && frame.minY >= top
            panGutter(in: app, upward: upward)
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThanOrEqual(element.frame.minY, top)
        XCTAssertLessThanOrEqual(element.frame.maxY, bottom)
    }

    @MainActor private func panGutter(in app: XCUIApplication, upward: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: upward ? 0.45 : 0.9))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private enum Direction { case up, down }
    @MainActor private func reveal(
        _ element: XCUIElement, in app: XCUIApplication, direction: Direction = .up
    ) {
        for _ in 0..<12 where !element.isHittable {
            panGutter(in: app, upward: direction == .up)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func launch(
        brand: String = "samsung", contentSizeCategory: String = "UICTContentSizeCategoryL",
        extra: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-ui-testing-in-memory-store", "-ui-testing-conveniences", "-convenience-\(brand)",
                "-UIPreferredContentSizeCategoryName", contentSizeCategory,
            ] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["Remote"].waitForExistence(timeout: 5))
        return app
    }
    @MainActor private func openMore(_ app: XCUIApplication) {
        let more = app.buttons["remoteMoreControls"]
        reveal(more, in: app)
        more.tap()
        XCTAssertTrue(app.navigationBars["More Controls"].waitForExistence(timeout: 2))
    }
    @MainActor private func backToRemote(_ app: XCUIApplication) {
        app.navigationBars["More Controls"].buttons["Remote"].tap()
        XCTAssertTrue(app.navigationBars["Remote"].waitForExistence(timeout: 2))
    }
    @MainActor private func assertTrace(_ value: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label == %@", value)
        let trace = app.staticTexts["convenienceFixtureTrace"]
        let condition = expectation(for: predicate, evaluatedWith: trace)
        let result = XCTWaiter.wait(for: [condition], timeout: 3)
        if result != .completed {
            let state = trace.exists ? "label=\(trace.label), frame=\(trace.frame)" : "observer missing"
            let diagnostic = XCTAttachment(string: "Expected \(value); \(state)\n\(app.debugDescription)")
            diagnostic.name = "Dispatch observer failure and application hierarchy"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
            attach(app, name: "Dispatch observer failure screenshot")
        }
        XCTAssertEqual(result, .completed, "Expected actual dispatch \(value)")
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
