import Foundation
import Testing

@testable import HafaRemote

struct VizioPairingCoordinatorTests {
    private let target: TVConnectionTarget
    private let info = VizioDeviceInfo(
        reportedDeviceID: "synthetic-vizio-serial",
        displayName: "Living Room",
        modelName: "TEST_VIZIO",
        firmwareVersion: "1.2.3"
    )

    init() throws {
        target = TVConnectionTarget(
            brand: .vizio,
            reportedDeviceID: "discovery-candidate",
            address: try PrivateIPv4Address("192.168.10.20"),
            controlPort: 7345
        )
    }

    @Test("First pairing persists the token and certificate only after the TV accepts its PIN")
    func firstPairingPersistsDeviceAttestedCredential() async throws {
        let fingerprint = Data(repeating: 7, count: 32)
        let client = StubVizioHTTPClient(info: info, fingerprint: fingerprint)
        let factory = VizioClientFactoryRecorder(clients: [client])
        let store = InMemoryVizioCredentialStore()
        let coordinator = VizioPairingCoordinator(
            credentialStore: store,
            makeClient: factory.makeClient
        )

        let tv = try await coordinator.pair(target: target) { challenge in
            #expect(challenge == VizioPairingChallenge(challengeType: 1, requestToken: 42))
            return "1234"
        }

        let identity = try VizioPairingIdentity(reportedDeviceID: info.reportedDeviceID)
        let credential = try #require(await store.credential(for: identity))
        #expect(tv.brand == .vizio)
        #expect(tv.reportedDeviceID == info.reportedDeviceID)
        #expect(tv.controlPort == 7345)
        #expect(credential.authToken == "synthetic-auth-token")
        #expect(credential.certificateSHA256 == fingerprint)
        #expect(UUID(uuidString: credential.clientID) != nil)
        #expect(await client.finishedPIN == "1234")
        #expect(await client.confirmationCount == 1)
    }

    @Test("A saved Vizio reconnect uses its certificate pin and skips the PIN prompt")
    func reconnectsWithSavedCredential() async throws {
        let fingerprint = Data(repeating: 8, count: 32)
        let identity = try VizioPairingIdentity(reportedDeviceID: info.reportedDeviceID)
        let credential = try VizioPairingCredential(
            authToken: "remembered-token",
            certificateSHA256: fingerprint,
            clientID: "00000000-0000-4000-8000-000000000001"
        )
        let store = InMemoryVizioCredentialStore()
        await store.save(credential, for: identity)
        let provisional = StubVizioHTTPClient(info: info)
        let pinned = StubVizioHTTPClient(info: info)
        let factory = VizioClientFactoryRecorder(clients: [provisional, pinned])
        let prompt = PINPromptRecorder()
        let coordinator = VizioPairingCoordinator(
            credentialStore: store,
            makeClient: factory.makeClient
        )

        _ = try await coordinator.pair(target: target) { challenge in
            await prompt.record(challenge)
            return "1234"
        }

        let requests = factory.requests
        #expect(requests.count == 2)
        #expect(requests[0].trustMode == .selectedPairingCandidate)
        #expect(requests[0].authToken == nil)
        #expect(requests[1].trustMode == .reconnect(expectedFingerprint: fingerprint))
        #expect(requests[1].authToken == "remembered-token")
        #expect(await pinned.deviceInfoTokens == ["remembered-token"])
        #expect(await prompt.count == 0)
    }

    @Test("Cancellation tells the TV to cancel pairing and stores no credential")
    func cancellationCancelsPairingWithoutPersistence() async throws {
        let client = StubVizioHTTPClient(info: info)
        let factory = VizioClientFactoryRecorder(clients: [client])
        let store = InMemoryVizioCredentialStore()
        let coordinator = VizioPairingCoordinator(
            credentialStore: store,
            makeClient: factory.makeClient
        )
        let prompt = SuspendedPINPrompt()
        let task = Task {
            try await coordinator.pair(target: target) { challenge in
                try await prompt.wait(challenge)
            }
        }

        await prompt.waitUntilPresented()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        let identity = try VizioPairingIdentity(reportedDeviceID: info.reportedDeviceID)
        #expect(await store.credential(for: identity) == nil)
        #expect(await client.cancelledClientIDs.count >= 1)
        #expect(await client.isDisconnected)
    }

    @Test("Remote commands use the active authenticated client")
    func sendsThroughActiveClient() async throws {
        let client = StubVizioHTTPClient(info: info)
        let coordinator = VizioPairingCoordinator(
            credentialStore: InMemoryVizioCredentialStore(),
            makeClient: VizioClientFactoryRecorder(clients: [client]).makeClient
        )
        _ = try await coordinator.pair(target: target) { _ in "1234" }

        try await coordinator.send(.volumeUp)

        #expect(await client.sentCommands == [.volumeUp])
    }

    @Test("A changed certificate never replaces a remembered credential")
    func rejectsChangedCertificateWithoutOverwritingCredential() async throws {
        let fingerprint = Data(repeating: 9, count: 32)
        let identity = try VizioPairingIdentity(reportedDeviceID: info.reportedDeviceID)
        let credential = try VizioPairingCredential(
            authToken: "remembered-token",
            certificateSHA256: fingerprint,
            clientID: "00000000-0000-4000-8000-000000000001"
        )
        let store = InMemoryVizioCredentialStore()
        await store.save(credential, for: identity)
        let provisional = StubVizioHTTPClient(info: info)
        let pinned = StubVizioHTTPClient(info: info, deviceInfoError: .certificateChanged)
        let coordinator = VizioPairingCoordinator(
            credentialStore: store,
            makeClient: VizioClientFactoryRecorder(clients: [provisional, pinned]).makeClient
        )

        await #expect(throws: VizioPairingCoordinatorError.certificateChanged) {
            try await coordinator.pair(target: target) { _ in "1234" }
        }
        #expect(await store.credential(for: identity) == credential)
    }
}

struct VizioPairingCredentialStoreTests {
    @Test("The Keychain store persists, reads, and removes one TV credential")
    func persistsAndRemovesCredential() async throws {
        let keychain = InMemoryVizioKeychain()
        let store = KeychainVizioPairingCredentialStore(keychain: keychain)
        let identity = try VizioPairingIdentity(reportedDeviceID: "synthetic-vizio-serial")
        let credential = try VizioPairingCredential(
            authToken: "synthetic-token",
            certificateSHA256: Data(repeating: 3, count: 32),
            clientID: "00000000-0000-4000-8000-000000000001"
        )

        try await store.save(credential, for: identity)
        #expect(try await store.credential(for: identity) == credential)
        try await store.remove(for: identity)
        #expect(try await store.credential(for: identity) == nil)
    }

    @Test("Corrupt Keychain data is removed before the error is reported")
    func discardsCorruptCredential() async throws {
        let keychain = InMemoryVizioKeychain(initialData: Data("not-json".utf8))
        let store = KeychainVizioPairingCredentialStore(keychain: keychain)
        let identity = try VizioPairingIdentity(reportedDeviceID: "synthetic-vizio-serial")

        await #expect(throws: VizioKeychainError.invalidStoredCredential) {
            try await store.credential(for: identity)
        }
        #expect(keychain.isEmpty)
    }
}

struct VizioDeviceInfoCodecTests {
    @Test("Modern device info yields nested identity and display metadata")
    func decodesModernDeviceInfo() throws {
        let response = Data(
            #"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"CNAME":"deviceinfo","NAME":"VIZIO Device Info","TYPE":"T_VIZIO_DEVICE_INFO_V1","VALUE":{"API_VERSION":"3.3.3-test","CAST_NAME":" Living Room ","MODEL_NAME":" VIZIO_TEST ","SYSTEM_INFO":{"MODEL_NAME":"VIZIO_TEST","SERIAL_NUMBER":" synthetic-serial-1 ","VERSION":" 1.2.3 "}}}]}"#
                .utf8
        )

        #expect(
            try VizioProtocolCodec.deviceInfo(from: response)
                == VizioDeviceInfo(
                    reportedDeviceID: "synthetic-serial-1",
                    displayName: "Living Room",
                    modelName: "VIZIO_TEST",
                    firmwareVersion: "1.2.3"
                )
        )
    }

    @Test("Legacy singular device info remains compatible")
    func decodesLegacyDeviceInfo() throws {
        let response = Data(
            #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"SERIAL_NUMBER":"synthetic-legacy-serial","CAST_NAME":"Office","MODEL_NAME":"VIZIO_LEGACY","VERSION":"9.8.7"}}"#
                .utf8
        )

        #expect(
            try VizioProtocolCodec.deviceInfo(from: response)
                == VizioDeviceInfo(
                    reportedDeviceID: "synthetic-legacy-serial",
                    displayName: "Office",
                    modelName: "VIZIO_LEGACY",
                    firmwareVersion: "9.8.7"
                )
        )
    }

    @Test("Missing and control-character identity fields are rejected")
    func rejectsUnsafeDeviceInfo() {
        let missingSerial = Data(
            #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"CAST_NAME":"Room","MODEL_NAME":"Model"}}"#.utf8
        )
        let controlCharacter = Data(
            #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"SERIAL_NUMBER":"serial\u0000","CAST_NAME":"Room","MODEL_NAME":"Model"}}"#
                .utf8
        )

        #expect(throws: VizioProtocolError.invalidResponse) {
            try VizioProtocolCodec.deviceInfo(from: missingSerial)
        }
        #expect(throws: VizioProtocolError.invalidResponse) {
            try VizioProtocolCodec.deviceInfo(from: controlCharacter)
        }
    }

    @Test("Only the documented Vizio SmartCast HTTPS ports are accepted")
    func validatesHTTPSPort() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        #expect(throws: VizioHTTPSClientError.invalidEndpoint) {
            try VizioHTTPSClient(
                address: address,
                port: 443,
                trustMode: .selectedPairingCandidate
            )
        }
        let client = try VizioHTTPSClient(
            address: address,
            port: 7345,
            trustMode: .selectedPairingCandidate
        )
        await client.disconnect()
    }
}

@Suite(.serialized)
struct VizioHTTPSClientRequestTests {
    @Test("The HTTPS client uses reviewed paths and sends AUTH only after pairing")
    func sendsAuthenticatedSmartCastRequests() async throws {
        let recorder = VizioRequestRecorder()
        VizioURLProtocolStub.install { request in
            recorder.record(request)
            let body: String
            switch request.url?.path {
            case "/state/device/deviceinfo":
                body =
                    #"{"STATUS":{"RESULT":"SUCCESS"},"ITEMS":[{"VALUE":{"CAST_NAME":"Living Room","MODEL_NAME":"VIZIO_TEST","SYSTEM_INFO":{"SERIAL_NUMBER":"synthetic-serial-1","VERSION":"1.2.3"}}}]}"#
            case "/pairing/start":
                body = #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"CHALLENGE_TYPE":1,"PAIRING_REQ_TOKEN":42}}"#
            case "/pairing/pair":
                body = #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"AUTH_TOKEN":"synthetic-auth-token"}}"#
            case "/pairing/cancel", "/key_command":
                body = #"{"STATUS":{"RESULT":"SUCCESS"}}"#
            default:
                return (404, Data(#"{"STATUS":{"RESULT":"NOT_FOUND"}}"#.utf8))
            }
            return (200, Data(body.utf8))
        }
        defer { VizioURLProtocolStub.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VizioURLProtocolStub.self]
        let client = try VizioHTTPSClient(
            address: PrivateIPv4Address("192.168.10.20"),
            port: 7345,
            trustMode: .selectedPairingCandidate,
            configuration: configuration
        )

        _ = try await client.deviceInfo(authToken: nil)
        let challenge = try await client.beginPairing(
            clientID: "00000000-0000-4000-8000-000000000001"
        )
        _ = try await client.finishPairing(
            clientID: "00000000-0000-4000-8000-000000000001",
            challenge: challenge,
            pin: "1234"
        )
        try await client.send(.volumeUp)
        await client.cancelPairing(clientID: "00000000-0000-4000-8000-000000000001")
        await client.disconnect()

        let requests = recorder.requests
        #expect(
            requests.map(\.urlPath) == [
                "/state/device/deviceinfo",
                "/pairing/start",
                "/pairing/pair",
                "/key_command",
                "/pairing/cancel",
            ])
        #expect(requests.map(\.method) == ["GET", "PUT", "PUT", "PUT", "PUT"])
        #expect(requests[0].authHeader == nil)
        #expect(requests[1].authHeader == nil)
        #expect(requests[2].authHeader == nil)
        #expect(requests[3].authHeader == "synthetic-auth-token")
        #expect(requests[4].authHeader == nil)
    }

    @Test("The trust delegate refuses redirects away from the selected TV endpoint")
    func blocksCrossEndpointRedirects() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let delegate = VizioTrustDelegate(
            address: address,
            port: 7345,
            mode: .selectedPairingCandidate
        )
        let originalURL = try #require(URL(string: "https://192.168.10.20:7345/source"))
        let response = try #require(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://192.168.10.21:7345/target"]
            )
        )
        let redirectedURL = try #require(URL(string: "https://192.168.10.21:7345/target"))
        let task = URLSession.shared.dataTask(with: originalURL)
        var acceptedRequest: URLRequest?

        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { request in
            acceptedRequest = request
        }

        #expect(acceptedRequest == nil)
    }
}

private actor StubVizioHTTPClient: VizioHTTPClienting {
    private let info: VizioDeviceInfo
    private let fingerprint: Data
    private let deviceInfoError: VizioHTTPSClientError?
    private(set) var deviceInfoTokens: [String?] = []
    private(set) var finishedPIN: String?
    private(set) var confirmationCount = 0
    private(set) var cancelledClientIDs: [String] = []
    private(set) var sentCommands: [RemoteCommand] = []
    private(set) var isDisconnected = false

    init(
        info: VizioDeviceInfo,
        fingerprint: Data = Data(repeating: 1, count: 32),
        deviceInfoError: VizioHTTPSClientError? = nil
    ) {
        self.info = info
        self.fingerprint = fingerprint
        self.deviceInfoError = deviceInfoError
    }

    func deviceInfo(authToken: String?) throws -> VizioDeviceInfo {
        deviceInfoTokens.append(authToken)
        if let deviceInfoError { throw deviceInfoError }
        return info
    }

    func beginPairing(clientID: String) -> VizioPairingChallenge {
        VizioPairingChallenge(challengeType: 1, requestToken: 42)
    }

    func finishPairing(
        clientID: String,
        challenge: VizioPairingChallenge,
        pin: String
    ) -> String {
        finishedPIN = pin
        return "synthetic-auth-token"
    }

    func cancelPairing(clientID: String) {
        cancelledClientIDs.append(clientID)
    }

    func confirmDeviceAttestedPairing() -> Data {
        confirmationCount += 1
        return fingerprint
    }

    func send(_ command: RemoteCommand) {
        sentCommands.append(command)
    }

    func sendText(_ input: RemoteTextInput) throws {
        throw TVDriverError.unsupportedTextInput
    }

    func disconnect() {
        isDisconnected = true
    }
}

private struct RecordedVizioRequest: Sendable {
    let urlPath: String
    let method: String
    let authHeader: String?
}

private final class VizioRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedVizioRequest] = []

    var requests: [RecordedVizioRequest] {
        lock.withLock { storage }
    }

    func record(_ request: URLRequest) {
        let snapshot = RecordedVizioRequest(
            urlPath: request.url?.path ?? "",
            method: request.httpMethod ?? "",
            authHeader: request.value(forHTTPHeaderField: "AUTH")
        )
        lock.withLock { storage.append(snapshot) }
    }
}

private final class VizioURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        let (statusCode, data) = handler(request)
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct VizioClientRequest: Equatable {
    let trustMode: VizioTrustMode
    let authToken: String?
}

private final class VizioClientFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any VizioHTTPClienting]
    private var recordedRequests: [VizioClientRequest] = []

    init(clients: [any VizioHTTPClienting]) {
        self.clients = clients
    }

    var requests: [VizioClientRequest] {
        lock.withLock { recordedRequests }
    }

    func makeClient(
        address: PrivateIPv4Address,
        port: UInt16,
        trustMode: VizioTrustMode,
        authToken: String?
    ) throws -> any VizioHTTPClienting {
        try lock.withLock {
            guard !clients.isEmpty else { throw VizioHTTPSClientError.unavailable }
            recordedRequests.append(
                VizioClientRequest(trustMode: trustMode, authToken: authToken)
            )
            return clients.removeFirst()
        }
    }
}

private actor InMemoryVizioCredentialStore: VizioPairingCredentialStoring {
    private var values: [VizioPairingIdentity: VizioPairingCredential] = [:]

    func credential(for identity: VizioPairingIdentity) -> VizioPairingCredential? {
        values[identity]
    }

    func save(_ credential: VizioPairingCredential, for identity: VizioPairingIdentity) {
        values[identity] = credential
    }

    func remove(for identity: VizioPairingIdentity) {
        values[identity] = nil
    }
}

private final class InMemoryVizioKeychain: VizioPairingCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var initialData: Data?

    init(initialData: Data? = nil) {
        self.initialData = initialData
    }

    var isEmpty: Bool {
        lock.withLock { values.isEmpty && initialData == nil }
    }

    func data(for account: String) -> Data? {
        lock.withLock { values[account] ?? initialData }
    }

    func save(_ data: Data, for account: String) {
        lock.withLock { values[account] = data }
    }

    func remove(account: String) {
        lock.withLock {
            values[account] = nil
            initialData = nil
        }
    }
}

private actor PINPromptRecorder {
    private(set) var count = 0

    func record(_ challenge: VizioPairingChallenge) {
        count += 1
    }
}

private actor SuspendedPINPrompt {
    private var continuation: CheckedContinuation<Void, Never>?
    private var presented = false

    func wait(_ challenge: VizioPairingChallenge) async throws -> String {
        presented = true
        continuation?.resume()
        continuation = nil
        try await Task.sleep(for: .seconds(60))
        return "1234"
    }

    func waitUntilPresented() async {
        guard !presented else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
