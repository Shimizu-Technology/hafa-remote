import Foundation
import Testing

@testable import HafaRemote

struct SamsungProtocolCodecTests {
    @Test("Select maps only to Samsung's reviewed enter key")
    func encodesSelect() throws {
        let message = try SamsungProtocolCodec.remoteMessage(for: .select)
        guard case .string(let text) = message else {
            Issue.record("Expected a text WebSocket message")
            return
        }

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let params = try #require(object["params"] as? [String: String])

        #expect(object["method"] as? String == "ms.remote.control")
        #expect(params["Cmd"] == "Click")
        #expect(params["DataOfCmd"] == "KEY_ENTER")
        #expect(params["Option"] == "false")
        #expect(params["TypeOfRemote"] == "SendRemoteKey")
    }

    @Test("Connect event returns only the pairing token")
    func decodesConnectEvent() throws {
        let message = URLSessionWebSocketTask.Message.string(
            #"{"event":"ms.channel.connect","data":{"token":"synthetic-token","id":"discard-me"}}"#
        )

        #expect(try SamsungProtocolCodec.event(from: message) == .connected(token: "synthetic-token"))
    }

    @Test("Unauthorized event is explicit")
    func decodesUnauthorizedEvent() throws {
        let message = URLSessionWebSocketTask.Message.string(
            #"{"event":"ms.channel.unauthorized","data":{}}"#
        )

        #expect(try SamsungProtocolCodec.event(from: message) == .unauthorized)
    }

    @Test(
        "Unrelated events ignore any data shape",
        arguments: [
            #"{"event":"ms.channel.clientConnect","data":"opaque"}"#,
            #"{"event":"ms.channel.clientDisconnect","data":[1,2,3]}"#,
        ]
    )
    func ignoresUnrelatedEventData(_ payload: String) throws {
        let message = URLSessionWebSocketTask.Message.string(payload)
        #expect(try SamsungProtocolCodec.event(from: message) == .ignored)
    }

    @Test("An event name is required")
    func rejectsMissingEventName() {
        let message = URLSessionWebSocketTask.Message.string(#"{"data":"opaque"}"#)
        #expect(throws: SamsungProtocolError.invalidEvent) {
            try SamsungProtocolCodec.event(from: message)
        }
    }

    @Test("Secure endpoint carries the encoded app name and optional token")
    func buildsSecureEndpoint() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let url = try SamsungWebSocketURLBuilder.url(address: address, token: "synthetic-token")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [])

        #expect(components.scheme == "wss")
        #expect(components.port == 8002)
        #expect(components.path == "/api/v2/channels/samsung.remote.control")
        #expect(query["name"] == Data("Hafa Remote".utf8).base64EncodedString())
        #expect(query["token"] == "synthetic-token")
    }

    @Test("First-pairing endpoint omits the token")
    func buildsFirstPairingEndpoint() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let url = try SamsungWebSocketURLBuilder.url(address: address, token: nil)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [])

        #expect(query["name"] == Data("Hafa Remote".utf8).base64EncodedString())
        #expect(query["token"] == nil)
    }

    @Test("Device parser retains only the reviewed capability fields")
    func parsesSafeDeviceInfo() throws {
        let response = Data(
            #"{"device":{"modelName":" TEST_MODEL_2021 ","firmwareVersion":" 1001.2 ","TokenAuthSupport":"true","wifiMac":"00:00:00:00:00:00","ssid":"synthetic-network"}}"#
                .utf8
        )

        let info = try SamsungDeviceInfoParser.parse(response)

        #expect(
            info
                == SamsungDeviceInfo(
                    modelName: "TEST_MODEL_2021",
                    firmwareVersion: "1001.2",
                    supportsTokenAuthentication: true
                )
        )
    }

    @Test("Pairing credentials reject control characters and malformed pins")
    func validatesCredentialShape() {
        #expect(throws: SamsungPairingCredentialError.invalidToken) {
            try SamsungPairingCredential(
                token: "unsafe\ntoken",
                certificateSHA256: Data(repeating: 1, count: 32)
            )
        }
        #expect(throws: SamsungPairingCredentialError.invalidCertificateFingerprint) {
            try SamsungPairingCredential(
                token: "synthetic-token",
                certificateSHA256: Data(repeating: 1, count: 31)
            )
        }
    }

    @Test("Decoded Keychain credentials pass through the same validation")
    func validatesDecodedCredentials() throws {
        let malformed = Data(
            """
            {"token":"","certificateSHA256":"\(Data(repeating: 1, count: 32).base64EncodedString())"}
            """.utf8
        )

        #expect(throws: SamsungPairingCredentialError.invalidToken) {
            try JSONDecoder().decode(SamsungPairingCredential.self, from: malformed)
        }
    }
}

struct SamsungConnectionAttemptTrackerTests {
    @Test("A superseded attempt cannot invalidate the current connection")
    func cleanupIsAttemptScoped() {
        var tracker = SamsungConnectionAttemptTracker()
        let first = SamsungConnectionAttemptID()
        let second = SamsungConnectionAttemptID()
        tracker.begin(first)
        tracker.begin(second)

        let supersededCleanupClosedConnection = tracker.finishIfCurrent(first)
        #expect(!supersededCleanupClosedConnection)
        #expect(tracker.isCurrent(second))
        let currentCleanupClosedConnection = tracker.finishIfCurrent(second)
        #expect(currentCleanupClosedConnection)
        #expect(!tracker.isCurrent(second))
    }
}

struct SamsungCommandSerializerTests {
    @Test("Concurrent commands execute in arrival order without overlap")
    func serializesCommands() async throws {
        let serializer = SamsungCommandSerializer()
        let recorder = CommandOrderRecorder()
        let (firstStarted, firstStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseFirst, releaseFirstContinuation) = AsyncStream<Void>.makeStream()
        let (secondAttempted, secondAttemptedContinuation) = AsyncStream<Void>.makeStream()

        let first = Task {
            try await serializer.perform {
                await recorder.append("first-start")
                firstStartedContinuation.yield()
                var releases = releaseFirst.makeAsyncIterator()
                _ = await releases.next()
                await recorder.append("first-end")
            }
        }
        var starts = firstStarted.makeAsyncIterator()
        _ = await starts.next()

        let second = Task {
            secondAttemptedContinuation.yield()
            try await serializer.perform {
                await recorder.append("second")
            }
        }
        var attempts = secondAttempted.makeAsyncIterator()
        _ = await attempts.next()
        await Task.yield()
        #expect(await recorder.values == ["first-start"])
        releaseFirstContinuation.yield()

        try await first.value
        try await second.value
        #expect(await recorder.values == ["first-start", "first-end", "second"])
        firstStartedContinuation.finish()
        releaseFirstContinuation.finish()
        secondAttemptedContinuation.finish()
    }

    @Test("A cancelled queued command is removed before execution")
    func removesCancelledWaiter() async throws {
        let serializer = SamsungCommandSerializer()
        let recorder = CommandOrderRecorder()
        let (firstStarted, firstStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseFirst, releaseFirstContinuation) = AsyncStream<Void>.makeStream()
        let (secondAttempted, secondAttemptedContinuation) = AsyncStream<Void>.makeStream()

        let first = Task {
            try await serializer.perform {
                await recorder.append("first-start")
                firstStartedContinuation.yield()
                var releases = releaseFirst.makeAsyncIterator()
                _ = await releases.next()
                await recorder.append("first-end")
            }
        }
        var starts = firstStarted.makeAsyncIterator()
        _ = await starts.next()

        let cancelled = Task {
            secondAttemptedContinuation.yield()
            try await serializer.perform {
                await recorder.append("cancelled-command")
            }
        }
        var attempts = secondAttempted.makeAsyncIterator()
        _ = await attempts.next()
        await Task.yield()
        cancelled.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await recorder.values == ["first-start"])
        releaseFirstContinuation.yield()
        try await first.value
        #expect(await recorder.values == ["first-start", "first-end"])

        firstStartedContinuation.finish()
        releaseFirstContinuation.finish()
        secondAttemptedContinuation.finish()
    }
}

struct SamsungTrustPolicyTests {
    private let firstFingerprint = Data(repeating: 1, count: 32)
    private let otherFingerprint = Data(repeating: 2, count: 32)

    @Test("Trust is restricted to the exact TV endpoint and a presented certificate")
    func rejectsUnscopedOrMissingCertificates() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        var policy = SamsungTrustPolicy(
            address: address,
            mode: .firstPairingRequiringOnTVApproval
        )

        #expect(
            policy.evaluate(
                host: "192.168.10.21",
                port: 8002,
                presentedFingerprint: firstFingerprint
            ) == .reject(.unexpectedEndpoint)
        )
        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 8001,
                presentedFingerprint: firstFingerprint
            ) == .reject(.unexpectedEndpoint)
        )
        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 8002,
                presentedFingerprint: nil
            ) == .reject(.missingCertificate)
        )
    }

    @Test("A first-pairing ceremony rejects a certificate change mid-handshake")
    func pinsFirstPairingCandidate() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        var policy = SamsungTrustPolicy(
            address: address,
            mode: .firstPairingRequiringOnTVApproval
        )

        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 8002,
                presentedFingerprint: firstFingerprint
            ) == .accept
        )
        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 8002,
                presentedFingerprint: otherFingerprint
            ) == .reject(.certificateChanged)
        )
    }

    @Test("Reconnect accepts only the saved certificate fingerprint")
    func enforcesReconnectPin() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        var mismatchPolicy = SamsungTrustPolicy(
            address: address,
            mode: .reconnect(expectedFingerprint: firstFingerprint)
        )
        #expect(
            mismatchPolicy.evaluate(
                host: address.rawValue,
                port: 8002,
                presentedFingerprint: otherFingerprint
            ) == .reject(.certificateChanged)
        )

        var matchingPolicy = SamsungTrustPolicy(
            address: address,
            mode: .reconnect(expectedFingerprint: firstFingerprint)
        )
        #expect(
            matchingPolicy.evaluate(
                host: address.rawValue,
                port: 8002,
                presentedFingerprint: firstFingerprint
            ) == .accept
        )
    }
}

private actor CommandOrderRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
