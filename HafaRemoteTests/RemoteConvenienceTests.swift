import Foundation
import Testing

@testable import HafaRemote

struct RemoteConvenienceTests {
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

private actor ConvenienceTestDriver: RemoteSessionDriving {
    nonisolated let brand = TVBrand.samsung
    private(set) var commandCount = 0
    private(set) var requestCount = 0
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
            reportedDeviceID: target.reportedDeviceID, address: target.address, modelName: "Synthetic",
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
    func disconnect() {}
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
