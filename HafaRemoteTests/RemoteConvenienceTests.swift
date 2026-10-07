import Foundation
import Testing

@testable import HafaRemote

struct RemoteConvenienceTests {
    @Test("A held cancelled Samsung address result cannot replace Sony routing")
    func staleAddressRouterResult() async throws {
        let callback = HeldRouterResult()
        let a = try routingTV(brand: .samsung, id: "synthetic-a")
        let b = try routingTV(brand: .sony, id: "synthetic-b")
        let samsung = RoutingSamsungSpy(result: a, held: callback)
        let sony = RoutingSonySpy(result: b)
        let vizio = RoutingVizioSpy()
        let router = MultiBrandSessionDriver(
            samsung: samsung, sony: sony, vizio: vizio, distributionPolicy: .internalCandidate)
        let old = Task { try await router.connect(addressText: "192.0.2.10") {} }
        await callback.waitUntilStarted()
        old.cancel()
        _ = try await router.connect(to: b.connectionTarget) {}
        let disconnects = await sony.disconnectCount
        await callback.release(a)
        if case .success = await old.result { Issue.record("Cancelled address result must not activate") }
        try await router.send(.right)
        #expect(await sony.commands == [.right])
        #expect(await samsung.commands.isEmpty)
        #expect(await sony.disconnectCount == disconnects)
        await router.disconnect()
    }

    @Test(
        "Stale target results and invalid identities cannot replace or disconnect Samsung routing",
        arguments: [false, true])
    func staleTargetRouterResult(invalidIdentity: Bool) async throws {
        let callback = HeldRouterResult()
        let a = try routingTV(brand: .sony, id: invalidIdentity ? "synthetic-wrong" : "synthetic-a")
        let b = try routingTV(brand: .samsung, id: "synthetic-b")
        let samsung = RoutingSamsungSpy(result: b)
        let sony = RoutingSonySpy(result: a, held: callback)
        let vizio = RoutingVizioSpy()
        let router = MultiBrandSessionDriver(
            samsung: samsung, sony: sony, vizio: vizio, distributionPolicy: .internalCandidate)
        let target = TVConnectionTarget(
            brand: .sony, reportedDeviceID: "synthetic-alias", address: a.address, controlPort: 6466,
            expectedSavedDeviceID: "synthetic-a")
        let old = Task { try await router.connect(to: target) {} }
        await callback.waitUntilStarted()
        // Intentionally do not cancel A: generation ownership alone must reject it.
        _ = try await router.connect(addressText: "192.0.2.11") {}
        let disconnects = await samsung.disconnectCount
        await callback.release(a)
        if case .success = await old.result { Issue.record("Stale target result must not activate") }
        try await router.send(.right)
        #expect(await samsung.commands == [.right])
        #expect(await sony.commands.isEmpty)
        #expect(await samsung.disconnectCount == disconnects)
        await router.disconnect()
    }

    private func routingTV(brand: TVBrand, id: String) throws -> ConnectedTV {
        ConnectedTV(
            brand: brand, reportedDeviceID: id,
            address: try .init(documentationAddressForTesting: "192.0.2.10"), modelName: "Synthetic",
            firmwareVersion: nil)
    }
    @Test("A late cancelled Sony connection callback cannot close the replacement session")
    func staleSonyConnectionCleanupIsAttemptOwned() async throws {
        let channel = ConvenienceSonyChannel()
        let coordinator = SonyPairingCoordinator(controlChannel: channel, keyboardPreference: { _ in true })
        let callback = HeldSonyConnectionCallback()
        let oldAttempt = Task {
            try await coordinator.attemptSyntheticConnectionForTesting(reportedFeatures: 615) {
                try await callback.waitForLateCallback()
            }
        }
        await callback.waitUntilStarted()
        oldAttempt.cancel()
        // Model the controller's explicit teardown after it stops waiting for A.
        await coordinator.disconnect()
        let replacement = try syntheticSony("synthetic-b")
        _ = try await coordinator.attemptSyntheticConnectionForTesting(reportedFeatures: 615) {
            await channel.setBehavior(.succeed)
            return replacement
        }
        let disconnects = await channel.disconnectCount
        await callback.completeCancelledCallback()
        if case .success = await oldAttempt.result { Issue.record("Cancelled A must not connect") }
        #expect(await channel.disconnectCount == disconnects)
        try await coordinator.checkConnection()
        try await coordinator.send(.right)
        #expect(await channel.sentCount == 1)
        await coordinator.disconnect()
    }

    @Test("Missing Sony protocol model uses a generic model, separate from display name")
    func genericSonyModelFallback() async throws {
        let info = SonyProtobuf.stringField(2, "Sony")
        let configure = SonyProtobuf.bytesField(
            1, SonyProtobuf.varintField(1, 2) + SonyProtobuf.bytesField(2, info))
        let power = SonyProtobuf.bytesField(40, SonyProtobuf.varintField(1, 1))
        let channel = ConvenienceSonyChannel(messages: [configure, power])
        let device = try await SonyRemoteHandshake.run(
            on: channel, fallbackModelName: "Sony Google TV", timeout: .seconds(1), maximumMessages: 8)
        #expect(device.model == "Sony Google TV")
    }

    @Test("Refreshing focus cannot renew expired Sony IME counters")
    func focusDoesNotRefreshCounters() throws {
        var focus = SonyIMEFocus()
        let start = ContinuousClock.now
        focus.focus(fieldCounter: 1, at: start)
        focus.counters(ime: 2, field: 1, at: start)
        let later = start.advanced(by: .seconds(16))
        focus.focus(fieldCounter: 1, at: later)
        #expect(throws: TVConvenienceError.textFieldNotFocused) { try focus.snapshot(at: later) }
        focus.counters(ime: 3, field: 1, at: later)
        #expect(try focus.snapshot(at: later).ime == 3)
        focus.focus(fieldCounter: 1, at: start)
        #expect(throws: TVConvenienceError.textFieldNotFocused) { try focus.snapshot(at: later) }
    }

    @MainActor
    @Test("Sony keyboard failed and cancelled writes leave negotiation and saved preference unchanged")
    func transactionalKeyboardFailure() async throws {
        let suite = "synthetic-keyboard-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TVConveniencePreferences(defaults: defaults)
        let channel = ConvenienceSonyChannel()
        let coordinator = SonyPairingCoordinator(
            controlChannel: channel, keyboardPreference: { preferences.keyboardEnabled(for: $0) })
        let tv = try syntheticSony("synthetic-a")
        try await coordinator.installSyntheticSessionForTesting(tv, reportedFeatures: 615)
        await coordinator.focusSyntheticFieldForTesting()
        await channel.setBehavior(.fail)
        do {
            _ = try await coordinator.convenience(.setKeyboardEnabled(false))
            Issue.record("Expected failed configuration write")
        } catch { #expect(error as? SonyTLSChannelError == .unavailable) }
        let failed = await coordinator.syntheticKeyboardStateForTesting()
        #expect(failed.enabled && failed.features == 615 && failed.hasFocus)
        #expect(preferences.keyboardEnabled(for: tv.stableDeviceKey))
        try await coordinator.installSyntheticSessionForTesting(tv, reportedFeatures: 615)
        await coordinator.focusSyntheticFieldForTesting()
        await channel.setBehavior(.stall)
        let task = Task { try await coordinator.convenience(.setKeyboardEnabled(false)) }
        await channel.waitUntilWriteStarted()
        task.cancel()
        if case .success = await task.result { Issue.record("Cancelled configuration must not commit") }
        let cancelled = await coordinator.syntheticKeyboardStateForTesting()
        #expect(cancelled.enabled && cancelled.features == 615 && cancelled.hasFocus)
        #expect(preferences.keyboardEnabled(for: tv.stableDeviceKey))
        try await coordinator.installSyntheticSessionForTesting(tv, reportedFeatures: 615)
        await channel.setBehavior(.stall)
        let stale = Task { try await coordinator.convenience(.setKeyboardEnabled(false)) }
        await channel.waitUntilWriteStarted()
        let replacement = try syntheticSony("synthetic-b")
        try await coordinator.installSyntheticSessionForTesting(replacement, reportedFeatures: 615)
        await channel.setBehavior(.succeed)
        stale.cancel()
        _ = await stale.result
        #expect(await coordinator.syntheticKeyboardStateForTesting().features == 615)
        try await coordinator.checkConnection()
        await coordinator.disconnect()
    }

    @MainActor
    @Test("Each Sony connection reloads its own saved keyboard preference")
    func perTVKeyboardPreference() async throws {
        let suite = "synthetic-keyboard-reconnect-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TVConveniencePreferences(defaults: defaults)
        let a = try syntheticSony("synthetic-a")
        let b = try syntheticSony("synthetic-b")
        try preferences.setKeyboardEnabled(false, for: a.stableDeviceKey)
        let coordinator = SonyPairingCoordinator(
            controlChannel: ConvenienceSonyChannel(),
            keyboardPreference: { preferences.keyboardEnabled(for: $0) })
        try await coordinator.installSyntheticSessionForTesting(a, reportedFeatures: 615)
        #expect(await coordinator.syntheticKeyboardStateForTesting().features == 611)
        try await coordinator.installSyntheticSessionForTesting(b, reportedFeatures: 615)
        #expect(await coordinator.syntheticKeyboardStateForTesting().features == 615)
        try await coordinator.installSyntheticSessionForTesting(a, reportedFeatures: 615)
        #expect(await coordinator.syntheticKeyboardStateForTesting().features == 611)
        await coordinator.disconnect()
    }

    @Test(
        "Cancelled Sony state-changing requests invalidate transport connectivity",
        arguments: [
            TVConvenienceRequest.launch(try! TVAppShortcut(name: "YouTube", target: .sony(.youtube))),
            .setKeyboardEnabled(false),
        ])
    func cancelledSonyRequestRecovers(_ request: TVConvenienceRequest) async throws {
        let driver = ConvenienceSonySessionDriver()
        let controller = RemoteSessionController(driver: driver)
        let target = TVConnectionTarget(
            brand: .sony, reportedDeviceID: "synthetic-a",
            address: try .init(documentationAddressForTesting: "192.0.2.10"), controlPort: 6466)
        await controller.connect(to: target)
        await driver.channel.setBehavior(.stall)
        let task = Task { try await controller.convenience(request, expectedDeviceKey: "sony:synthetic-a") }
        await driver.channel.waitUntilWriteStarted()
        task.cancel()
        if case .success = await task.result {
            Issue.record("Cancelled state-changing request must not succeed")
        }
        if case .connected = await controller.state {
            Issue.record("Cancelled TLS write cannot remain connected")
        }
        #expect(await driver.disconnectCount > 0)
        do {
            try await controller.send(.right, expectedDeviceKey: "sony:synthetic-a")
            Issue.record("Ordinary command must wait for recovery")
        } catch {}
        await controller.disconnect()
    }

    @Test(
        "Timed-out Sony writes recover instead of preserving connected",
        arguments: [
            TVConvenienceRequest.launch(try! TVAppShortcut(name: "YouTube", target: .sony(.youtube))),
            .setKeyboardEnabled(false),
        ])
    func timedOutSonyRequestRecovers(_ request: TVConvenienceRequest) async throws {
        let driver = ConvenienceSonySessionDriver()
        let controller = RemoteSessionController(
            driver: driver, clock: StartedWriteTimeoutClock(channel: driver.channel))
        let target = TVConnectionTarget(
            brand: .sony, reportedDeviceID: "synthetic-a",
            address: try .init(documentationAddressForTesting: "192.0.2.10"), controlPort: 6466)
        await controller.connect(to: target)
        await driver.channel.setBehavior(.stall)
        do {
            _ = try await controller.convenience(request, expectedDeviceKey: "sony:synthetic-a")
            Issue.record("Expected bounded write timeout")
        } catch { #expect(error as? RemoteSessionControllerError == .timedOut(.send)) }
        if case .connected = await controller.state {
            Issue.record("Timed-out TLS write cannot remain connected")
        }
        #expect(await driver.disconnectCount > 0)
        await controller.disconnect()
    }

    @Test("Cancelling an unexecuted FIFO write does not tear down a healthy current session")
    func cancelledQueueWaiterPreservesSession() async throws {
        let driver = ConvenienceTestDriver()
        let controller = RemoteSessionController(driver: driver)
        await controller.connect(to: try target("synthetic-a"))
        await driver.blockNextCommand()
        let first = Task { try await controller.send(.up, expectedDeviceKey: "samsung:synthetic-a") }
        await driver.waitUntilCommandBlocks()
        let disconnects = await driver.disconnectCount
        let app = try TVAppShortcut(
            name: "Synthetic", target: .samsung(appID: "synthetic-app", deepLink: true))
        let queued = Task {
            try await controller.convenience(.launch(app), expectedDeviceKey: "samsung:synthetic-a")
        }
        for _ in 0..<10 { await Task.yield() }
        queued.cancel()
        _ = await queued.result
        if case .connected = await controller.state {
        } else {
            Issue.record("A cancelled FIFO waiter must preserve transport")
        }
        #expect(await driver.disconnectCount == disconnects)
        #expect(await driver.requestCount == 0)
        first.cancel()
        _ = await first.result
        await controller.disconnect()
    }

    @MainActor
    @Test("A suspended old power-off cannot disconnect or clear the newly selected TV")
    func oldPowerOffDoesNotTearDownReplacement() async throws {
        let driver = ConvenienceTestDriver()
        let controller = RemoteSessionController(driver: driver)
        let store = RemoteSessionStore(controller: controller)
        await store.connect(to: try target("synthetic-a"))
        await driver.blockNextCommand()
        let oldPower = Task { try await store.powerOffSelectedTV(expectedDeviceKey: "samsung:synthetic-a") }
        await driver.waitUntilCommandBlocks()
        await store.connect(to: try target("synthetic-b"))
        let disconnects = await driver.disconnectCount
        if case .success = await oldPower.result { Issue.record("Stale power-off must not succeed") }
        for _ in 0..<10 { await Task.yield() }
        #expect(store.connectedTV?.stableDeviceKey == "samsung:synthetic-b")
        #expect(store.lastConnectedTV?.stableDeviceKey == "samsung:synthetic-b")
        #expect(await driver.disconnectCount == disconnects)
        await store.disconnect()
    }

    @MainActor
    @Test("Rebound Sony aliases wait for authenticated identity and stale wake guards reject connection")
    func reboundIdentityAndWakeOwnership() async throws {
        let driver = ConvenienceTestDriver()
        let controller = RemoteSessionController(driver: driver)
        let store = RemoteSessionStore(controller: controller)
        let address = try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.10")
        let rebound = TVConnectionTarget(
            brand: .samsung, reportedDeviceID: "synthetic-alias", address: address, controlPort: 8002,
            expectedSavedDeviceID: "synthetic-a")
        let result = try await store.connectAndWait(to: rebound, timeout: .seconds(1))
        #expect(result.stableDeviceKey == "samsung:synthetic-a")
        await store.connect(to: try target("synthetic-b"))
        do {
            _ = try await store.connectAndWait(to: rebound, timeout: .seconds(1), isStillSelected: { false })
            Issue.record("Stale wake must not restart A")
        } catch {}
        if case .connected(let current) = await controller.state {
            #expect(current.stableDeviceKey == "samsung:synthetic-b")
        } else {
            Issue.record("Stale wake must retain B")
        }
        await store.disconnect()
    }

    private func syntheticSony(_ id: String) throws -> ConnectedTV {
        ConnectedTV(
            brand: .sony, reportedDeviceID: id,
            address: try .init(documentationAddressForTesting: "192.0.2.10"), modelName: "Synthetic Sony",
            firmwareVersion: nil, powerState: .on)
    }
    @Test("Swipes produce one dominant-axis D-pad action and reject jitter")
    func swipeMapping() {
        #expect(RemoteSwipeMapping.command(horizontal: 30, vertical: 3) == .right)
        #expect(RemoteSwipeMapping.command(horizontal: -30, vertical: 3) == .left)
        #expect(RemoteSwipeMapping.command(horizontal: 3, vertical: 30) == .down)
        #expect(RemoteSwipeMapping.command(horizontal: 3, vertical: -30) == .up)
        #expect(RemoteSwipeMapping.command(horizontal: 23, vertical: 0) == nil)
        #expect(RemoteSwipeMapping.command(horizontal: 30, vertical: 30) == nil)
        #expect(RemoteSwipeMapping.command(horizontal: .nan, vertical: 30) == nil)
    }

    @MainActor
    @Test("Favorites are persisted per authenticated TV and removed when forgotten")
    func favoriteOwnership() throws {
        let suite = "synthetic-hafa-favorites-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = TVConveniencePreferences(defaults: defaults)
        let app = try TVAppShortcut(
            name: "Synthetic App", target: .samsung(appID: "synthetic-app", deepLink: true))
        try prefs.toggleFavorite(app, for: "samsung:synthetic-tv-a")
        #expect(prefs.favorites(for: "samsung:synthetic-tv-b").isEmpty)
        #expect(prefs.favorites(for: "sony:synthetic-tv-a").isEmpty)
        #expect(throws: TVConvenienceError.wrongTV) {
            try prefs.toggleFavorite(app, for: "sony:synthetic-tv-a")
        }
        let restored = TVConveniencePreferences(defaults: defaults)
        #expect(restored.favorites(for: "samsung:synthetic-tv-a") == [app])
        restored.forget(stableDeviceKey: "samsung:synthetic-tv-a")
        #expect(TVConveniencePreferences(defaults: defaults).favorites(for: "samsung:synthetic-tv-a").isEmpty)
    }

    @Test("Samsung app decoding is bounded, deduplicated, and excludes internal tools")
    func samsungApps() throws {
        let message = URLSessionWebSocketTask.Message.string(
            #"{"event":"ed.installedApp.get","data":{"data":[{"appId":"synthetic-app","name":"Synthetic App","app_type":2},{"appId":"synthetic-app","name":"Duplicate","app_type":2},{"appId":"org.synthetic.factory","name":"Factory Tool","app_type":1},{"appId":"invalid/address","name":"Invalid","app_type":1}]}}"#
        )
        let decodedApps = try SamsungAppCodec.apps(from: message)
        let apps = try #require(decodedApps)
        #expect(apps.count == 1)
        #expect(apps.first?.target == .samsung(appID: "synthetic-app", deepLink: true))
        #expect(try SamsungAppCodec.apps(from: .string(#"{"event":"ms.channel.ready"}"#)) == nil)
        #expect(throws: TVConvenienceError.invalidResponse) {
            try SamsungAppCodec.apps(from: .string(#"{"event":"ed.installedApp.get","data":{}}"#))
        }
        let request = try stringObject(SamsungAppCodec.request())
        #expect(request["method"] as? String == "ms.channel.emit")
        let launch = try stringObject(SamsungAppCodec.launch(try #require(apps.first)))
        let params = try #require(launch["params"] as? [String: Any])
        let payload = try #require(params["data"] as? [String: Any])
        #expect(payload["action_type"] as? String == "DEEP_LINK")
        #expect(payload["metaTag"] as? String == "")
    }

    @Test("Samsung app query times out, ignores late responses, and resets for a new socket")
    func boundedSamsungQuery() async throws {
        let query = SamsungAppListQuery()
        do {
            _ = try await query.query(timeout: .milliseconds(1), send: {})
            Issue.record("Expected bounded app query timeout")
        } catch { #expect(error as? TVConvenienceError == .timedOut) }
        await query.receive(.success([]))
        do {
            _ = try await query.query(send: {})
            Issue.record("A timed-out session must reject a new indistinguishable query")
        } catch { #expect(error as? TVConvenienceError == .unavailable) }
        await query.reset()
        let apps = try await query.query(send: { await query.receive(.success([])) })
        #expect(apps.isEmpty)
    }

    @Test("Vizio inputs use returned values and a freshly supplied HASHVAL")
    func vizioInputs() throws {
        let inputs = try VizioConvenienceCodec.inputs(
            from: Data(
                #"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"CNAME":"hdmi1_name","NAME":"HDMI-1","VALUE":{"NAME":"Synthetic Console"}},{"CNAME":"current_input"}]}"#
                    .utf8))
        #expect(inputs == [try TVInputSource(value: "HDMI-1", name: "Synthetic Console")])
        let hash = try VizioConvenienceCodec.currentInputHash(
            from: Data(
                #"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"CNAME":"current_input","HASHVAL":789,"VALUE":"HDMI-2"}]}"#
                    .utf8))
        let input = try #require(inputs.first)
        let body = try VizioConvenienceCodec.selectInput(input, currentHash: hash)
        let object = try JSONSerialization.jsonObject(with: body)
        let write = try #require(object as? [String: Any])
        #expect(write["HASHVAL"] as? Int == 789)
        #expect(write["VALUE"] as? String == "HDMI-1")
        #expect(write["REQUEST"] as? String == "MODIFY")
    }

    @Test("Vizio favorites never store dynamic MESSAGE or casting state")
    func vizioApps() throws {
        let decodedApp = try VizioConvenienceCodec.currentApp(
            from: Data(
                #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"VALUE":{"APP_ID":"synthetic-app","NAME_SPACE":3,"MESSAGE":null}}}"#
                    .utf8))
        let app = try #require(decodedApp)
        #expect(app.target == .vizio(appID: "synthetic-app", namespace: 3))
        let body = try VizioConvenienceCodec.launch(app)
        let object = try JSONSerialization.jsonObject(with: body)
        let launch = try #require(object as? [String: Any])
        let value = try #require(launch["VALUE"] as? [String: Any])
        #expect(value["MESSAGE"] is NSNull)
        #expect(throws: TVConvenienceError.unavailable) {
            try VizioConvenienceCodec.currentApp(
                from: Data(
                    #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"VALUE":{"APP_ID":"synthetic-app","NAME_SPACE":3,"MESSAGE":"synthetic-private-stream"}}}"#
                        .utf8))
        }
        for command in RemoteCommand.allCases where command.digit != nil || command == .guide {
            #expect(throws: VizioProtocolError.unsupportedCommand) {
                try VizioProtocolCodec.remoteCommand(command)
            }
        }
    }

    @Test("Sony keyboard requires matching fresh focus/counters and uses UTF-16 selections")
    func sonyIME() throws {
        var focus = SonyIMEFocus()
        #expect(throws: TVConvenienceError.textFieldNotFocused) { try focus.snapshot() }
        focus.focus(fieldCounter: 4)
        focus.counters(ime: 9, field: 3)
        #expect(throws: TVConvenienceError.textFieldNotFocused) { try focus.snapshot() }
        focus.counters(ime: 10, field: 4)
        #expect(throws: TVConvenienceError.textFieldNotFocused) {
            try focus.snapshot(at: .now.advanced(by: .seconds(16)))
        }
        let counters = try focus.snapshot()
        #expect(counters.ime == 10 && counters.field == 4)
        let input = try RemoteTextInput("A👋e\u{301}")
        let outer = try SonyProtobuf.fields(
            in: SonyConvenienceCodec.text(input, imeCounter: counters.ime, fieldCounter: counters.field))
        let batch = try SonyProtobuf.fields(in: try #require(outer.first?.bytes))
        let edit = try SonyProtobuf.fields(in: try #require(batch.first(where: { $0.number == 3 })?.bytes))
        let field = try SonyProtobuf.fields(in: try #require(edit.first(where: { $0.number == 2 })?.bytes))
        #expect(field.first(where: { $0.number == 1 })?.varint == UInt64(input.value.utf16.count - 1))
        #expect(field.first(where: { $0.number == 2 })?.varint == UInt64(input.value.utf16.count - 1))
        focus.clear()
        #expect(throws: TVConvenienceError.textFieldNotFocused) { try focus.snapshot() }
    }

    @Test("Sony IME event parsing discards incoming field content")
    func sonyFocusEvents() throws {
        let status = SonyProtobuf.varintField(1, 2) + SonyProtobuf.stringField(2, "synthetic private text")
        let message = SonyProtobuf.bytesField(20, SonyProtobuf.bytesField(2, status))
        #expect(try SonyRemoteProtocolCodec.parse(message) == .imeFocus(2))
        #expect(try SonyRemoteProtocolCodec.parse(SonyProtobuf.bytesField(20, Data())) == .imeFocus(nil))
        let event = SonyProtobuf.bytesField(
            21, SonyProtobuf.varintField(1, 7) + SonyProtobuf.varintField(2, 2))
        #expect(try SonyRemoteProtocolCodec.parse(event) == .imeCounters(ime: 7, field: 2))
    }

    @Test("Sony app links are a bounded catalog and require negotiated feature bits")
    func sonyAppLinks() throws {
        #expect(TVAppShortcut.sonyConfiguredLinks.count == 4)
        #expect(!SonyRemoteDevice.capabilities(for: 99).contains(.textInput))
        #expect(!SonyRemoteDevice.capabilities(for: 99).contains(.favoriteApps))
        #expect(SonyRemoteDevice.capabilities(for: 615).contains(.textInput))
        #expect(SonyRemoteDevice.capabilities(for: 615).contains(.favoriteApps))
        let app = try #require(TVAppShortcut.sonyConfiguredLinks.first)
        let fields = try SonyProtobuf.fields(in: SonyConvenienceCodec.launch(app))
        #expect(fields.first?.number == 90)
        let link = try SonyProtobuf.fields(in: try #require(fields.first?.bytes))
        #expect(String(data: try #require(link.first?.bytes), encoding: .utf8) == SonyAppLink.youtube.value)
    }

    @Test("Suspended TV A view actions cannot control newly selected TV B")
    func delayedOldViewAction() async throws {
        let driver = ConvenienceTestDriver()
        let controller = RemoteSessionController(driver: driver)
        await controller.connect(to: try target("synthetic-a"))
        let gate = DelayedConvenienceViewGate()
        let gesture = Task {
            await gate.wait()
            try await controller.send(.right, expectedDeviceKey: "samsung:synthetic-a")
        }
        let launch = Task {
            await gate.wait()
            return try await controller.convenience(.apps, expectedDeviceKey: "samsung:synthetic-a")
        }
        await gate.waitUntilBothStarted()
        await controller.connect(to: try target("synthetic-b"))
        await gate.release()
        do {
            try await gesture.value
            Issue.record("An old swipe must be rejected")
        } catch { #expect(error as? TVConvenienceError == .wrongTV) }
        do {
            _ = try await launch.value
            Issue.record("An old app request must be rejected")
        } catch { #expect(error as? TVConvenienceError == .wrongTV) }
        #expect(await driver.commandCount == 0)
        #expect(await driver.requestCount == 0)
        await controller.disconnect()
    }

    @Test("Manual pairing selects brand ports without turning an address into identity")
    func manualTargets() throws {
        let address = try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.10")
        for (brand, port) in [(TVBrand.samsung, UInt16(8002)), (.sony, 6466), (.vizio, 7345)] {
            let target = ManualTVTargetFactory.target(address: address, brand: brand)
            #expect(target.brand == brand)
            #expect(target.controlPort == port)
            #expect(target.expectedSavedDeviceID == nil)
            #expect(target.reportedDeviceID != address.rawValue)
        }
        let saved = TVConnectionTarget(
            brand: .sony, reportedDeviceID: "synthetic-authenticated-id", address: address, controlPort: 6466,
            expectedSavedDeviceID: "synthetic-authenticated-id", discoveryIdentifier: "synthetic-alias")
        let moved = try PrivateIPv4Address(documentationAddressForTesting: "198.51.100.12")
        let repaired = ManualTVTargetFactory.target(address: moved, brand: .sony, savedTarget: saved)
        #expect(repaired.expectedSavedDeviceID == saved.expectedSavedDeviceID)
        #expect(repaired.discoveryIdentifier == saved.discoveryIdentifier)
        #expect(repaired.address == moved)
        #expect(
            ManualTVTargetFactory.target(address: moved, brand: .vizio, savedTarget: saved)
                .expectedSavedDeviceID == nil)
        #expect(throws: PrivateIPv4AddressError.notPrivate) { try PrivateIPv4Address("192.0.2.10") }
    }

    @Test("A queued convenience is cancelled when TV selection changes")
    func queuedConvenienceDoesNotCrossTVs() async throws {
        let driver = ConvenienceTestDriver()
        let controller = RemoteSessionController(driver: driver)
        await controller.connect(to: try target("synthetic-a"))
        await driver.blockNextCommand()
        let command = Task { try await controller.send(.up, expectedDeviceKey: "samsung:synthetic-a") }
        await driver.waitUntilCommandBlocks()
        let request = Task {
            try await controller.convenience(.apps, expectedDeviceKey: "samsung:synthetic-a")
        }
        await Task.yield()
        await controller.connect(to: try target("synthetic-b"))
        _ = await command.result
        if case .success = await request.result { Issue.record("An old queued request must not execute") }
        #expect(await driver.commandCount == 0)
        #expect(await driver.requestCount == 0)
        await controller.disconnect()
    }

    @Test("Vizio selects with fresh input metadata in exactly three local requests")
    func vizioFreshHashTransaction() async throws {
        let probe = VizioConvenienceHTTPProtocol.probe
        probe.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VizioConvenienceHTTPProtocol.self]
        let client = try VizioHTTPSClient(
            address: PrivateIPv4Address(documentationAddressForTesting: "192.0.2.10"),
            port: 7345,
            trustMode: .reconnect(expectedFingerprint: Data(repeating: 1, count: 32)),
            authToken: "synthetic-pairing-token",
            configuration: configuration
        )
        let input = try TVInputSource(value: "HDMI-1", name: "Synthetic Console")
        #expect(try await client.convenience(.selectInput(input)) == .sent)
        await client.disconnect()
        let requests = probe.snapshot()
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "PUT"])
        #expect(
            requests.map { $0.url?.path } == [
                VizioConvenienceCodec.inputsPath, VizioConvenienceCodec.currentInputPath,
                VizioConvenienceCodec.currentInputPath,
            ])
        let body = try #require(requests.last?.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let payload = try #require(object as? [String: Any])
        #expect(payload["HASHVAL"] as? Int == 789)
        #expect(payload["VALUE"] as? String == "HDMI-1")
    }

    private func target(_ id: String) throws -> TVConnectionTarget {
        TVConnectionTarget(
            brand: .samsung, reportedDeviceID: id,
            address: try .init(documentationAddressForTesting: "192.0.2.10"),
            controlPort: 8002)
    }
    private func stringObject(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        guard case .string(let text) = message,
            let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw TVConvenienceError.invalidResponse }
        return result
    }
}

private actor HeldRouterResult {
    private var result: CheckedContinuation<ConnectedTV, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async -> ConnectedTV {
        await withCheckedContinuation {
            result = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release(_ television: ConnectedTV) {
        result?.resume(returning: television)
        result = nil
    }
}

private actor RoutingSamsungSpy: SamsungPairingCoordinating {
    let result: ConnectedTV
    let held: HeldRouterResult?
    private(set) var commands: [RemoteCommand] = []
    private(set) var disconnectCount = 0
    init(result: ConnectedTV, held: HeldRouterResult? = nil) {
        self.result = result
        self.held = held
    }
    func pair(addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void)
        async throws -> ConnectedTV
    {
        if let held { return await held.wait() }
        return result
    }
    func send(_ command: RemoteCommand) { commands.append(command) }
    func forget(addressText: String) {}
    func disconnect() { disconnectCount += 1 }
}

private actor RoutingSonySpy: SonyPairingCoordinating {
    let result: ConnectedTV
    let held: HeldRouterResult?
    private(set) var commands: [RemoteCommand] = []
    private(set) var disconnectCount = 0
    init(result: ConnectedTV, held: HeldRouterResult? = nil) {
        self.result = result
        self.held = held
    }
    func connect(to target: TVConnectionTarget, requestPairingCode: @escaping SonyPairingCodeProvider)
        async throws -> ConnectedTV
    {
        if let held { return await held.wait() }
        return result
    }
    func send(_ command: RemoteCommand) { commands.append(command) }
    func forget(reportedDeviceID: String) {}
    func disconnect() { disconnectCount += 1 }
}

private actor RoutingVizioSpy: VizioPairingCoordinating {
    func pair(target: TVConnectionTarget, pinProvider: @escaping VizioPINProvider) async throws -> ConnectedTV
    { throw TVConvenienceError.unavailable }
    func send(_ command: RemoteCommand) {}
    func forget(reportedDeviceID: String) {}
    func disconnect() {}
}

private actor ConvenienceTestDriver: RemoteSessionDriving {
    nonisolated let brand = TVBrand.samsung
    private(set) var commandCount = 0
    private(set) var requestCount = 0
    private(set) var disconnectCount = 0
    private var shouldBlock = false
    private var blocked = false
    private var blockStarted: CheckedContinuation<Void, Never>?
    func blockNextCommand() { shouldBlock = true }
    func waitUntilCommandBlocks() async {
        if blocked { return }
        await withCheckedContinuation { blockStarted = $0 }
    }
    func connect(addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void)
        async throws -> ConnectedTV
    {
        throw TVConvenienceError.unavailable
    }
    func connect(
        to target: TVConnectionTarget, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
        ConnectedTV(
            reportedDeviceID: target.expectedSavedDeviceID ?? target.reportedDeviceID,
            address: target.address, modelName: "Synthetic",
            firmwareVersion: nil)
    }
    func send(_ command: RemoteCommand) async throws {
        if shouldBlock {
            shouldBlock = false
            blocked = true
            blockStarted?.resume()
            blockStarted = nil
            try await Task.sleep(for: .seconds(60))
        }
        try Task.checkCancellation()
        commandCount += 1
    }
    func convenience(_ request: TVConvenienceRequest) -> TVConvenienceResponse {
        requestCount += 1
        return .apps([])
    }
    func disconnect() { disconnectCount += 1 }
    func forget(addressText: String) {}
}

private final class VizioConvenienceHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let probe = VizioConvenienceHTTPProbe()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "192.0.2.10" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.probe.response(for: request)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class VizioConvenienceHTTPProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        requests = []
    }
    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
    func response(for request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 { captured.httpBody = Data(buffer.prefix(count)) }
        }
        requests.append(captured)
        let json: String
        if request.url?.path == VizioConvenienceCodec.inputsPath {
            json =
                #"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"CNAME":"hdmi1_name","NAME":"HDMI-1","VALUE":{"NAME":"Synthetic Console"}}]}"#
        } else if request.httpMethod == "GET" {
            json =
                #"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"CNAME":"current_input","HASHVAL":789,"VALUE":"HDMI-2"}]}"#
        } else {
            json = #"{"STATUS":{"RESULT":"SUCCESS"}}"#
        }
        return Data(json.utf8)
    }
}

private actor DelayedConvenienceViewGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 2 {
                started?.resume()
                started = nil
            }
        }
    }
    func waitUntilBothStarted() async {
        if waiters.count == 2 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor ConvenienceSonyChannel: SonyTLSChanneling {
    enum Behavior { case succeed, fail, stall }
    private var messages: [Data]
    init(messages: [Data] = []) { self.messages = messages }
    private var behavior: Behavior = .succeed
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var closed = false
    private(set) var disconnectCount = 0
    private(set) var sentCount = 0
    private var connectionGeneration = UUID()
    func setBehavior(_ value: Behavior) {
        behavior = value
        connectionGeneration = UUID()
        started = false
        closed = false
    }
    func waitUntilWriteStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func connect(
        address: PrivateIPv4Address, port: UInt16, identity: SonyClientIdentityReference,
        trustMode: SonyTLSTrustMode
    ) async throws -> SonyTLSPeer { throw SonyTLSChannelError.unavailable }
    func send(_ message: Data) async throws {
        guard !closed else { throw SonyTLSChannelError.connectionClosed }
        sentCount += 1
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        switch behavior {
        case .succeed: return
        case .fail: throw SonyTLSChannelError.unavailable
        case .stall:
            let ownerGeneration = connectionGeneration
            do { try await Task.sleep(for: .seconds(60)) } catch {
                if connectionGeneration == ownerGeneration { closed = true }
                throw CancellationError()
            }
        }
    }
    func receive() async throws -> Data {
        guard !messages.isEmpty else { throw SonyTLSChannelError.connectionClosed }
        return messages.removeFirst()
    }
    func checkConnection() throws { if closed { throw SonyTLSChannelError.connectionClosed } }
    func disconnect() {
        disconnectCount += 1
        connectionGeneration = UUID()
        closed = true
    }
}

private actor ConvenienceSonySessionDriver: RemoteSessionDriving {
    nonisolated let brand = TVBrand.sony
    nonisolated func cancellationInvalidatesConnection() async -> Bool { true }
    let channel = ConvenienceSonyChannel()
    private var coordinator: SonyPairingCoordinator?
    private(set) var disconnectCount = 0
    func connect(addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void)
        async throws -> ConnectedTV
    { throw SonyTLSChannelError.unavailable }
    func connect(
        to target: TVConnectionTarget, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
        let tv = ConnectedTV(
            brand: .sony, reportedDeviceID: target.reportedDeviceID, address: target.address,
            modelName: "Synthetic", firmwareVersion: nil, powerState: .on)
        let coordinator = SonyPairingCoordinator(controlChannel: channel, keyboardPreference: { _ in true })
        try await coordinator.installSyntheticSessionForTesting(tv, reportedFeatures: 615)
        await channel.setBehavior(.succeed)
        self.coordinator = coordinator
        return tv
    }
    func send(_ command: RemoteCommand) async throws {
        guard let coordinator else { throw SonyTLSChannelError.connectionClosed }
        try await coordinator.send(command)
    }
    func convenience(_ request: TVConvenienceRequest) async throws -> TVConvenienceResponse {
        guard let coordinator else { throw SonyTLSChannelError.connectionClosed }
        return try await coordinator.convenience(request)
    }
    func disconnect() async {
        disconnectCount += 1
        await coordinator?.disconnect()
        coordinator = nil
    }
    func forget(addressText: String) {}
}

private struct StartedWriteTimeoutClock: RemoteSessionClock {
    let channel: ConvenienceSonyChannel
    func sleep(for duration: Duration) async throws {
        if duration == .seconds(10) {
            await channel.waitUntilWriteStarted()
            try await Task.sleep(for: .milliseconds(1))
        } else {
            try await Task.sleep(for: duration)
        }
    }
}

private actor HeldSonyConnectionCallback {
    private var continuation: CheckedContinuation<ConnectedTV, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func waitForLateCallback() async throws -> ConnectedTV {
        // Intentionally ignores cancellation until the simulated TLS callback arrives.
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func completeCancelledCallback() {
        continuation?.resume(throwing: SonyTLSChannelError.unavailable)
        continuation = nil
    }
}
