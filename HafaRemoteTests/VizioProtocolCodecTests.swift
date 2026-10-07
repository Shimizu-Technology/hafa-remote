import Foundation
import Testing

@testable import HafaRemote

struct VizioProtocolCodecTests {
    @Test(
        "Vizio same-input selection reads fresh state without sending a redundant PUT",
        arguments: [
            InputReviewScenario.sameIdentifier, .sameUpperName, .sameLowerName, .different, .ambiguousAlias,
            .unlisted, .missingHash, .missingValue, .failedStatus,
        ])
    func inputSelectionNoOp(scenario: InputReviewScenario) async throws {
        let host = "192.0.2.\(170 + scenario.rawValue)"
        let probe = VizioInputReviewProbe(scenario: scenario)
        VizioInputReviewRegistry.shared.install(probe, host: host)
        defer { VizioInputReviewRegistry.shared.remove(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VizioInputReviewHTTPProtocol.self]
        let client = try VizioHTTPSClient(
            address: PrivateIPv4Address(documentationAddressForTesting: host), port: 7345,
            trustMode: .reconnect(expectedFingerprint: Data(repeating: 7, count: 32)),
            authToken: "synthetic-input-review-token", configuration: configuration)
        let input = try TVInputSource(
            value: scenario == .unlisted ? "HDMI-9" : "HDMI-1", name: "Synthetic Console")
        do {
            #expect(try await client.convenience(.selectInput(input)) == .sent)
            #expect(!scenario.shouldFail)
        } catch {
            #expect(scenario.shouldFail)
        }
        await client.disconnect()
        let requests = probe.snapshot()
        let expected =
            scenario == .unlisted ? ["GET"] : scenario.shouldPut ? ["GET", "GET", "PUT"] : ["GET", "GET"]
        #expect(requests.map(\.httpMethod) == expected)
        if scenario.shouldPut {
            let body = try #require(requests.last?.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["HASHVAL"] as? Int == 789)
            #expect(object["VALUE"] as? String == "HDMI-1")
        }
    }

    @Test("Vizio power_mode accepts only successful numeric 0 or 1 observations")
    func powerModeIsTruthful() {
        let fixtures: [(String, TVPowerState)] = [
            (#"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"VALUE":1}]}"#, .on),
            (#"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"VALUE":0}]}"#, .standby),
            (#"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"VALUE":1}}"#, .on),
            (#"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"VALUE":2}]}"#, .unknown),
            (#"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"VALUE":true}]}"#, .unknown),
            (#"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"VALUE":"1"}]}"#, .unknown),
            (#"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{}]}"#, .unknown),
            (#"{"STATUS":{"RESULT":"SUCCESS"}}"#, .unknown),
            (#"{"STATUS":{"RESULT":"FAILURE"},"ITEMS":[{"VALUE":1}]}"#, .unknown),
            ("invalid-json", .unknown),
        ]
        for (json, expected) in fixtures {
            #expect(VizioProtocolCodec.powerState(from: Data(json.utf8)) == expected)
        }
    }

    @Test("Every remote action maps to one reviewed Vizio keypress")
    func encodesRemoteCommands() throws {
        let expected: [RemoteCommand: (Int, Int)] = [
            .powerOn: (11, 1),
            .powerOff: (11, 0),
            .up: (3, 8),
            .down: (3, 0),
            .left: (3, 1),
            .right: (3, 7),
            .select: (3, 2),
            .home: (4, 15),
            .back: (4, 0),
            .play: (2, 3),
            .pause: (2, 2),
            .rewind: (2, 1),
            .fastForward: (2, 0),
            .volumeUp: (5, 1),
            .volumeDown: (5, 0),
            .mute: (5, 4),
            .inputSource: (7, 1),
            .channelUp: (8, 1),
            .channelDown: (8, 0),
        ]

        #expect(expected.count == RemoteCommand.allCases.filter { $0.digit == nil && $0 != .guide }.count)
        for command in expected.keys {
            let object = try jsonObject(VizioProtocolCodec.remoteCommand(command))
            let keys = try #require(object["KEYLIST"] as? [[String: Any]])
            let key = try #require(keys.first)
            let mapping = try #require(expected[command])

            #expect(keys.count == 1)
            #expect(key["CODESET"] as? Int == mapping.0)
            #expect(key["CODE"] as? Int == mapping.1)
            #expect(key["ACTION"] as? String == "KEYPRESS")
        }
    }

    @Test("Vizio guide and all numeric commands remain outside the reviewed allowlist")
    func unsupportedGuideAndDigits() {
        let commands = RemoteCommand.allCases.filter { $0 == .guide || $0.digit != nil }
        #expect(commands.count == 11)
        for command in commands {
            #expect(throws: VizioProtocolError.unsupportedCommand) {
                try VizioProtocolCodec.remoteCommand(command)
            }
        }
    }

    @Test("Pairing requests contain only the stable client identity and PIN ceremony fields")
    func encodesPairingRequests() throws {
        let clientID = "00000000-0000-4000-8000-000000000001"
        let begin = try jsonObject(VizioProtocolCodec.beginPairing(deviceID: clientID))
        let finish = try jsonObject(
            VizioProtocolCodec.finishPairing(
                deviceID: clientID,
                challenge: VizioPairingChallenge(challengeType: 1, requestToken: 42),
                pin: "1234"
            )
        )

        #expect(begin["DEVICE_ID"] as? String == clientID)
        #expect(begin["DEVICE_NAME"] as? String == "Hafa Remote")
        #expect(Set(begin.keys) == ["DEVICE_ID", "DEVICE_NAME"])
        #expect(finish["DEVICE_ID"] as? String == clientID)
        #expect(finish["CHALLENGE_TYPE"] as? Int == 1)
        #expect(finish["PAIRING_REQ_TOKEN"] as? Int == 42)
        #expect(finish["RESPONSE_VALUE"] as? String == "1234")
        #expect(
            Set(finish.keys)
                == ["DEVICE_ID", "CHALLENGE_TYPE", "PAIRING_REQ_TOKEN", "RESPONSE_VALUE"]
        )

        let cancel = try jsonObject(VizioProtocolCodec.cancelPairing(deviceID: clientID))
        #expect(Set(cancel.keys) == ["DEVICE_ID", "DEVICE_NAME"])
        #expect(cancel["DEVICE_ID"] as? String == clientID)
        #expect(cancel["DEVICE_NAME"] as? String == "Hafa Remote")
        #expect(throws: VizioProtocolError.invalidResponse) {
            try VizioProtocolCodec.finishPairing(
                deviceID: clientID,
                challenge: VizioPairingChallenge(challengeType: 1, requestToken: 42),
                pin: "12A4"
            )
        }
    }

    @Test("Pairing responses expose only the challenge and auth token")
    func decodesPairingResponses() throws {
        let challenge = Data(
            #"{"STATUS":{"RESULT":"SUCCESS","DETAIL":"ignored"},"ITEM":{"CHALLENGE_TYPE":1,"PAIRING_REQ_TOKEN":42,"DEVICE_NAME":"ignored"}}"#
                .utf8
        )
        let token = Data(
            #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"AUTH_TOKEN":" synthetic-token ","EXTRA":"ignored"}}"#
                .utf8
        )

        #expect(
            try VizioProtocolCodec.pairingChallenge(from: challenge)
                == VizioPairingChallenge(challengeType: 1, requestToken: 42)
        )
        #expect(try VizioProtocolCodec.authToken(from: token) == "synthetic-token")
        #expect(throws: VizioProtocolError.invalidResponse) {
            try VizioProtocolCodec.authToken(
                from: Data(
                    #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"AUTH_TOKEN":"token\u0000value"}}"#.utf8
                )
            )
        }
    }

    @Test("Device failures remain typed and never become success")
    func rejectsFailureResponses() {
        let rejected = Data(#"{"STATUS":{"RESULT":"PAIRING_DENIED"}}"#.utf8)

        #expect(throws: VizioProtocolError.rejected("PAIRING_DENIED")) {
            try VizioProtocolCodec.requireSuccess(from: rejected)
        }
        #expect(throws: VizioProtocolError.invalidResponse) {
            try VizioProtocolCodec.requireSuccess(from: Data(#"{"ITEM":{}}"#.utf8))
        }
    }

    @Test("Pairing state only advances through the TV-confirmed PIN ceremony")
    func pairingStateTransitions() throws {
        let challenge = VizioPairingChallenge(challengeType: 1, requestToken: 42)
        var paired = VizioPairingStateMachine()
        try paired.apply(.receivedChallenge(challenge))
        #expect(paired.state == .awaitingPIN(challenge))
        try paired.apply(.acceptedPIN)
        #expect(paired.state == .paired)
        #expect(throws: VizioProtocolError.invalidPairingTransition) {
            try paired.apply(.cancelled)
        }

        var cancelled = VizioPairingStateMachine()
        try cancelled.apply(.receivedChallenge(challenge))
        try cancelled.apply(.cancelled)
        #expect(cancelled.state == .cancelled)

        var failed = VizioPairingStateMachine()
        try failed.apply(.failed)
        #expect(failed.state == .failed)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

struct VizioPairingCredentialTests {
    @Test("Credentials and TV identity validate and redact secret material")
    func validatesCredential() throws {
        let token = "synthetic-secret-token"
        let credential = try VizioPairingCredential(
            authToken: token,
            certificateSHA256: Data(repeating: 1, count: 32),
            clientID: "00000000-0000-4000-8000-000000000001"
        )
        let identity = try VizioPairingIdentity(reportedDeviceID: " synthetic-vizio-id ")

        #expect(credential.authToken == token)
        #expect(!String(describing: credential).contains(token))
        #expect(identity.reportedDeviceID == "synthetic-vizio-id")
        #expect(identity.stableDeviceKey == "vizio:synthetic-vizio-id")
        #expect(!String(describing: identity).contains("synthetic-vizio-id"))

        let encoded = try JSONEncoder().encode(credential)
        let decoded = try JSONDecoder().decode(VizioPairingCredential.self, from: encoded)
        #expect(decoded == credential)
    }

    @Test("Malformed credential fields are rejected")
    func rejectsMalformedCredential() {
        #expect(throws: VizioPairingCredentialError.invalidAuthToken) {
            try VizioPairingCredential(
                authToken: "",
                certificateSHA256: Data(repeating: 1, count: 32),
                clientID: UUID().uuidString
            )
        }
        #expect(throws: VizioPairingCredentialError.invalidCertificateFingerprint) {
            try VizioPairingCredential(
                authToken: "token",
                certificateSHA256: Data(repeating: 1, count: 31),
                clientID: UUID().uuidString
            )
        }
        #expect(throws: VizioPairingCredentialError.invalidClientID) {
            try VizioPairingCredential(
                authToken: "token",
                certificateSHA256: Data(repeating: 1, count: 32),
                clientID: "shared-client"
            )
        }
    }
}

struct VizioTrustPolicyTests {
    @Test("First pairing trusts one certificate only at the selected private endpoint")
    func scopesFirstPairingTrust() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let first = Data(repeating: 1, count: 32)
        let changed = Data(repeating: 2, count: 32)
        var policy = VizioTrustPolicy(
            address: address,
            port: 7345,
            mode: .selectedPairingCandidate
        )

        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 7345,
                presentedFingerprint: first
            ) == .accept
        )
        #expect(policy.candidateFingerprint == nil)
        let confirmed = policy.confirmDeviceAttestedPairing()
        #expect(confirmed)
        #expect(policy.candidateFingerprint == first)
        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 7345,
                presentedFingerprint: changed
            ) == .reject(.certificateChanged)
        )
        #expect(
            policy.evaluate(host: "192.168.10.21", port: 7345, presentedFingerprint: first)
                == .reject(.unexpectedEndpoint)
        )
        #expect(
            policy.evaluate(host: address.rawValue, port: 9000, presentedFingerprint: first)
                == .reject(.unexpectedEndpoint)
        )
    }

    @Test("An initial certificate is persisted only after the TV accepts its displayed PIN")
    func requiresDeviceAttestedPairingBeforePersistence() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let fingerprint = Data(repeating: 5, count: 32)
        var policy = VizioTrustPolicy(
            address: address,
            port: 7345,
            mode: .selectedPairingCandidate
        )

        let prematureConfirmation = policy.confirmDeviceAttestedPairing()
        #expect(!prematureConfirmation)
        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 7345,
                presentedFingerprint: fingerprint
            ) == .accept
        )
        #expect(policy.candidateFingerprint == nil)
        let confirmed = policy.confirmDeviceAttestedPairing()
        #expect(confirmed)
        #expect(policy.candidateFingerprint == fingerprint)
    }

    @Test("Reconnect accepts only the saved certificate fingerprint")
    func pinsReconnectCertificate() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let saved = Data(repeating: 3, count: 32)
        var matching = VizioTrustPolicy(
            address: address,
            port: 9000,
            mode: .reconnect(expectedFingerprint: saved)
        )
        var changed = matching

        #expect(
            matching.evaluate(
                host: address.rawValue,
                port: 9000,
                presentedFingerprint: saved
            ) == .accept
        )
        #expect(
            changed.evaluate(
                host: address.rawValue,
                port: 9000,
                presentedFingerprint: Data(repeating: 4, count: 32)
            ) == .reject(.certificateChanged)
        )
    }

    @Test("The URL session delegate defaults unrelated auth and cancels missing server trust")
    func delegatesAuthenticationChallengesSafely() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let delegate = VizioTrustDelegate(
            address: address,
            port: 7345,
            mode: .selectedPairingCandidate
        )
        let sender = VizioChallengeSender()
        let unrelated = URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: address.rawValue,
                port: 7345,
                protocol: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            ),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        var unrelatedDisposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, didReceive: unrelated) { disposition, _ in
            unrelatedDisposition = disposition
        }

        #expect(unrelatedDisposition == .performDefaultHandling)
        #expect(delegate.failure == nil)

        let missingTrust = URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: address.rawValue,
                port: 7345,
                protocol: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodServerTrust
            ),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        var missingTrustDisposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, didReceive: missingTrust) { disposition, _ in
            missingTrustDisposition = disposition
        }

        #expect(missingTrustDisposition == .cancelAuthenticationChallenge)
        #expect(delegate.failure == .missingCertificate)
        #expect(delegate.candidateFingerprint == nil)
        #expect(!delegate.confirmDeviceAttestedPairing())
        #expect(String(describing: delegate) == "VizioTrustDelegate(redacted)")
    }
}

private final class VizioChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
    func cancel(_: URLAuthenticationChallenge) {}
    func performDefaultHandling(for _: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {}
}

enum InputReviewScenario: Int, CaseIterable, Sendable {
    case sameIdentifier, sameUpperName, sameLowerName, different, ambiguousAlias, unlisted, missingHash,
        missingValue, failedStatus
    var shouldFail: Bool { self == .unlisted || self == .missingHash || self == .failedStatus }
    var shouldPut: Bool { self == .different || self == .ambiguousAlias || self == .missingValue }
}

private final class VizioInputReviewRegistry: @unchecked Sendable {
    static let shared = VizioInputReviewRegistry()
    private let lock = NSLock()
    private var probes: [String: VizioInputReviewProbe] = [:]
    func install(_ probe: VizioInputReviewProbe, host: String) { lock.withLock { probes[host] = probe } }
    func remove(host: String) { _ = lock.withLock { probes.removeValue(forKey: host) } }
    func probe(host: String) -> VizioInputReviewProbe? { lock.withLock { probes[host] } }
}

private final class VizioInputReviewProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let scenario: InputReviewScenario
    init(scenario: InputReviewScenario) { self.scenario = scenario }
    func snapshot() -> [URLRequest] { lock.withLock { requests } }
    func response(_ request: URLRequest) throws -> Data {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw TVConvenienceError.invalidResponse }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 16_384 else { throw TVConvenienceError.invalidResponse }
            }
            captured.httpBody = bytes
        }
        lock.withLock { requests.append(captured) }
        if request.httpMethod == "PUT" { return Data(#"{"STATUS":{"RESULT":"SUCCESS"}}"#.utf8) }
        if request.url?.path == VizioConvenienceCodec.inputsPath {
            let secondName = scenario == .ambiguousAlias ? "Synthetic Console" : "Synthetic Other"
            return try JSONSerialization.data(withJSONObject: [
                "STATUS": ["RESULT": "SUCCESS"],
                "ITEMS": [
                    ["CNAME": "hdmi_1", "NAME": "HDMI-1", "VALUE": ["NAME": "Synthetic Console"]],
                    ["CNAME": "hdmi_2", "NAME": "HDMI-2", "VALUE": ["NAME": secondName]],
                ],
            ])
        }
        var row: [String: Any] = ["CNAME": "current_input", "HASHVAL": 789]
        switch scenario {
        case .sameIdentifier, .unlisted, .missingHash: row["VALUE"] = "HDMI-1"
        case .sameUpperName: row["VALUE"] = ["NAME": "hdmi-1"]
        case .sameLowerName, .ambiguousAlias: row["VALUE"] = ["name": "Synthetic Console"]
        case .different: row["VALUE"] = "HDMI-2"
        case .missingValue: break
        case .failedStatus: row["VALUE"] = "HDMI-1"
        }
        if scenario == .missingHash { row.removeValue(forKey: "HASHVAL") }
        return try JSONSerialization.data(withJSONObject: [
            "STATUS": ["RESULT": scenario == .failedStatus ? "FAILURE" : "SUCCESS"], "ITEMS": [row],
        ])
    }
}

private final class VizioInputReviewHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let host = try #require(request.url?.host)
            let probe = try #require(VizioInputReviewRegistry.shared.probe(host: host))
            let data = try probe.response(request)
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
