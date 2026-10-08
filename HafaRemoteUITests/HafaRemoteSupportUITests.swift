import XCTest

final class HafaRemoteSupportUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDiagnosticsConsentImmutablePreviewShareCancelAndClear() {
        let app = launch()
        openDiagnostics(app)
        let toggle = app.switches["diagnosticsToggle"]
        XCTAssertEqual(toggle.value as? String, "0")
        let clear = app.buttons["Clear Events"]
        XCTAssertFalse(clear.isEnabled)
        tap(app.buttons["previewDiagnosticsButton"], in: app)
        let report = app.staticTexts["diagnosticsReportPreview"]
        XCTAssertTrue(report.waitForExistence(timeout: 3))
        XCTAssertTrue(report.label.contains("No events recorded"))
        app.navigationBars["Support Report"].buttons["Done"].tap()

        setCollection(true, toggle: toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        cycleLifecycle(app)
        waitEnabled(clear)
        tap(app.buttons["previewDiagnosticsButton"], in: app)
        XCTAssertTrue(report.waitForExistence(timeout: 3))
        XCTAssertTrue(report.label.contains("App backgrounded"))
        let snapshot = report.label
        cycleLifecycle(app)
        XCTAssertEqual(report.label, snapshot, "Live collection cannot change the preview being shared")
        tap(app.buttons["shareDiagnosticsButton"], in: app)
        cancelNativeShare(in: app)
        XCTAssertTrue(app.navigationBars["Support Report"].waitForExistence(timeout: 3))
        XCTAssertEqual(report.label, snapshot)
        app.navigationBars["Support Report"].buttons["Done"].tap()
        tap(app.buttons["previewDiagnosticsButton"], in: app)
        XCTAssertTrue(report.waitForExistence(timeout: 3))
        XCTAssertNotEqual(report.label, snapshot, "A newly requested preview reflects later events")
        app.navigationBars["Support Report"].buttons["Done"].tap()
        tap(clear, in: app)
        XCTAssertFalse(clear.isEnabled)
        assertEmptyPreview(app)

        cycleLifecycle(app)
        waitEnabled(clear)
        setCollection(false, toggle: toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(clear.isEnabled)
        cycleLifecycle(app)
        XCTAssertFalse(clear.isEnabled)
        assertEmptyPreview(app)
        setCollection(true, toggle: toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(clear.isEnabled)
        assertEmptyPreview(app)
        app.terminate()
        app.launch()
        openDiagnostics(app)
        XCTAssertEqual(app.switches["diagnosticsToggle"].value as? String, "0")
    }

    @MainActor
    func testOfflineDemoPowerPlaybackTextAndReentry() {
        let app = launch()
        openDemo(app)
        tap(app.buttons["demo-right"], in: app)
        tap(app.buttons["demo-select"], in: app)
        XCTAssertTrue(app.staticTexts["demoActivity"].label.contains("Listen"))
        tap(app.buttons["demo-home"], in: app)
        tap(app.buttons["demo-volumeUp"], in: app)
        XCTAssertTrue(app.staticTexts["demoVolumeState"].label.contains("21"))
        tap(app.buttons["demo-mute"], in: app)
        XCTAssertTrue(app.staticTexts["demoVolumeState"].label.contains("muted"))
        tap(app.buttons["demo-play"], in: app)
        XCTAssertTrue(app.buttons["demo-pause"].exists)
        tap(app.buttons["demo-pause"], in: app)
        XCTAssertTrue(app.buttons["demo-play"].exists)
        tap(app.buttons["demo-powerOff"], in: app, upward: false)
        XCTAssertFalse(app.buttons["demo-up"].isEnabled)
        XCTAssertFalse(app.buttons["demo-select"].isEnabled)
        tap(app.buttons["demo-powerOn"], in: app)
        XCTAssertTrue(app.buttons["demo-up"].isEnabled)
        let field = app.textFields["demoTextField"]
        tap(field, in: app)
        field.typeText("Synthetic demo")
        tap(app.buttons["demoSendTextButton"], in: app)
        XCTAssertFalse((field.value as? String ?? "").contains("Synthetic demo"))
        XCTAssertFalse(app.buttons["demoSendTextButton"].isEnabled)
        XCTAssertTrue(app.staticTexts["demoActivity"].label.contains("No text was sent to a TV"))
        app.navigationBars["Try the Remote"].buttons["Help"].tap()
        let returnedToHelp = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.navigationBars["Try the Remote"])
        wait(for: [returnedToHelp], timeout: 3)
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 3))
        tap(app.buttons["openOfflineDemoButton"], in: app)
        let restoredVolume = app.staticTexts["demoVolumeState"]
        reveal(restoredVolume, in: app, upward: false)
        let volumeNodes = app.staticTexts.matching(identifier: "demoVolumeState").allElementsBoundByIndex
        let evidence = volumeNodes.map { "label=\($0.label), frame=\($0.frame), hittable=\($0.isHittable)" }
            .joined(separator: "; ")
        let visibleVolume = volumeNodes.first(where: { $0.isHittable }) ?? restoredVolume
        XCTAssertTrue(visibleVolume.label.contains("20"), "Visible reentry volume: \(evidence)")
        XCTAssertTrue(app.buttons["demo-play"].exists)
        XCTAssertTrue(app.buttons["demo-powerOff"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @MainActor
    func testLargestTextSupportControlsRemainReachable() {
        let app = launch(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        openDemo(app)
        for name in ["demo-right", "demo-select", "demo-volumeUp", "demo-play", "demoSendTextButton"] {
            let button = app.buttons[name]
            reveal(button, in: app)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        app.navigationBars["Try the Remote"].buttons["Help"].tap()
        tap(app.buttons["openDiagnosticsButton"], in: app)
        let toggle = app.switches["diagnosticsToggle"]
        setCollection(true, toggle: toggle, in: app)
        cycleLifecycle(app)
        tap(app.buttons["previewDiagnosticsButton"], in: app)
        let share = app.buttons["shareDiagnosticsButton"]
        reveal(share, in: app)
        XCTAssertGreaterThanOrEqual(share.frame.width, 44)
        XCTAssertGreaterThanOrEqual(share.frame.height, 44)
        let done = app.navigationBars["Support Report"].buttons["Done"]
        XCTAssertTrue(done.isHittable)
        XCTAssertGreaterThanOrEqual(done.frame.width, 44)
        XCTAssertGreaterThanOrEqual(done.frame.height, 44)
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Synthetic-support-largest-text"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor private func launch(contentSize: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-in-memory-store", "-UIPreferredContentSizeCategoryName", contentSize,
        ]
        app.launch()
        XCTAssertTrue(app.buttons["homeHelpButton"].waitForExistence(timeout: 5))
        return app
    }
    /// A toolbar control belongs inside its navigation bar, above the scroll body's viewport.
    @MainActor private func openSupport(_ app: XCUIApplication) {
        let help = app.buttons["homeHelpButton"]
        XCTAssertTrue(help.waitForExistence(timeout: 3))
        XCTAssertTrue(help.isHittable)
        XCTAssertGreaterThanOrEqual(help.frame.width, 44)
        XCTAssertGreaterThanOrEqual(help.frame.height, 44)
        // Tap the padded label's near corner to verify its whole 44-point hit region.
        help.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
    }
    @MainActor private func openDemo(_ app: XCUIApplication) {
        openSupport(app)
        tap(app.buttons["openOfflineDemoButton"], in: app)
        XCTAssertTrue(app.staticTexts["offlineDemoLabel"].waitForExistence(timeout: 3))
    }
    @MainActor private func openDiagnostics(_ app: XCUIApplication) {
        openSupport(app)
        tap(app.buttons["openDiagnosticsButton"], in: app)
        XCTAssertTrue(app.switches["diagnosticsToggle"].waitForExistence(timeout: 3))
    }
    @MainActor private func assertEmptyPreview(_ app: XCUIApplication) {
        tap(app.buttons["previewDiagnosticsButton"], in: app)
        let report = app.staticTexts["diagnosticsReportPreview"]
        XCTAssertTrue(report.waitForExistence(timeout: 3))
        XCTAssertTrue(report.label.contains("No events recorded"))
        app.navigationBars["Support Report"].buttons["Done"].tap()
    }
    @MainActor private func cycleLifecycle(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 3))
    }
    @MainActor private func setCollection(_ enabled: Bool, toggle: XCUIElement, in app: XCUIApplication) {
        reveal(toggle, in: app, upward: false)
        // SwiftUI's combined switch accessibility frame includes the label; hit the native thumb.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let changed = expectation(
            for: NSPredicate(format: "value == %@", enabled ? "1" : "0"), evaluatedWith: toggle)
        wait(for: [changed], timeout: 3)
    }
    @MainActor private func cancelNativeShare(in app: XCUIApplication) {
        // Both native presentations must contain the activity UI before cancellation.
        let activity = app.collectionViews["activityCollectionView"]
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        let close = app.buttons["Close"]
        if close.exists {
            XCTAssertTrue(close.isHittable)
            close.tap()
        } else {
            // iOS 26 presents the activity sheet as a popover with a native dismiss region.
            let dismiss = app.otherElements["PopoverDismissRegion"]
            let popover = app.popovers.firstMatch
            XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
            XCTAssertTrue(popover.exists)
            let pointY = popover.frame.minY - 20
            XCTAssertGreaterThan(pointY, dismiss.frame.minY)
            XCTAssertLessThan(pointY, popover.frame.minY)
            let cancelPoint = CGPoint(x: dismiss.frame.midX, y: pointY)
            XCTAssertTrue(dismiss.frame.contains(cancelPoint))
            XCTAssertFalse(popover.frame.contains(cancelPoint))
            XCTAssertFalse(activity.frame.contains(cancelPoint))
            dismiss.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.5, dy: (pointY - dismiss.frame.minY) / dismiss.frame.height)
            ).tap()
        }
        let dismissed = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: activity)
        wait(for: [dismissed], timeout: 3)
    }

    @MainActor private func bodyBottom(in app: XCUIApplication) -> CGFloat {
        let keyboard = app.keyboards.firstMatch
        let keyboardTop =
            keyboard.exists && keyboard.frame.height > 0 ? keyboard.frame.minY - 8 : app.frame.maxY
        return min(app.frame.maxY - 44, keyboardTop)
    }
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element)
        wait(for: [enabled], timeout: 3)
    }
    @MainActor private func tap(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        reveal(element, in: app, upward: upward)
        element.tap()
    }
    /// A sheet can expose its presenting bar too; use the deepest support route's own bar.
    @MainActor private func activeSupportBar(in app: XCUIApplication) -> XCUIElement {
        for title in ["Support Report", "Diagnostics", "Try the Remote", "Help"] {
            let bar = app.navigationBars[title]
            if bar.exists { return bar }
        }
        XCTFail("The expected support route is not present")
        return app.navigationBars.firstMatch
    }

    /// Use the actual scroll viewport, including a visible keyboard, and the active sheet's bar.
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<16 {
            let bar = activeSupportBar(in: app)
            let top = bar.frame.maxY + 8
            let bottom = bodyBottom(in: app)
            if element.exists, element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom {
                return
            }
            let movesUp = element.exists ? element.frame.maxY > bottom : upward
            XCTAssertGreaterThan(bottom - top, 44, "The actual scroll viewport must contain a control")
            let height = bottom - top
            let fromY = top + height * (movesUp ? 0.75 : 0.25)
            let toY = top + height * (movesUp ? 0.35 : 0.65)
            let from = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.05, dy: (fromY - app.frame.minY) / app.frame.height))
            let to = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.05, dy: (toY - app.frame.minY) / app.frame.height))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable, "Unable to reveal \(element.identifier) in its support viewport")
        XCTAssertGreaterThanOrEqual(element.frame.minY, activeSupportBar(in: app).frame.maxY + 8)
        XCTAssertLessThanOrEqual(element.frame.maxY, bodyBottom(in: app))
    }
}
