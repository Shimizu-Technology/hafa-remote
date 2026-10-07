import Foundation

protocol VizioHTTPClienting: TVDriver {
    func deviceInfo(authToken: String?) async throws -> VizioDeviceInfo
    func beginPairing(clientID: String) async throws -> VizioPairingChallenge
    func finishPairing(
        clientID: String,
        challenge: VizioPairingChallenge,
        pin: String
    ) async throws -> String
    func cancelPairing(clientID: String) async
    func confirmDeviceAttestedPairing() async throws -> Data
}

/// Owns one endpoint-scoped HTTPS session for a Vizio SmartCast television.
actor VizioHTTPSClient: VizioHTTPClienting {
    private static let allowedPorts: Set<UInt16> = [7345, 9000]
    private static let maximumResponseBytes = 1_048_576

    private let address: PrivateIPv4Address
    private let port: UInt16
    private let trustDelegate: VizioTrustDelegate
    private let session: URLSession
    private var authToken: String?
    private var isDisconnected = false
    private var didReadInputs = false
    private var didReadAppConfiguration = false
    private var reportedDeviceID: String?

    nonisolated static func supports(controlPort: UInt16) -> Bool {
        allowedPorts.contains(controlPort)
    }

    init(
        address: PrivateIPv4Address,
        port: UInt16,
        trustMode: VizioTrustMode,
        authToken: String? = nil,
        requestTimeout: TimeInterval = 10,
        resourceTimeout: TimeInterval = 15,
        configuration suppliedConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard Self.supports(controlPort: port) else {
            throw VizioHTTPSClientError.invalidEndpoint
        }
        self.address = address
        self.port = port
        self.authToken = authToken
        let delegate = VizioTrustDelegate(address: address, port: port, mode: trustMode)
        trustDelegate = delegate

        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func deviceInfo(authToken: String?) async throws -> VizioDeviceInfo {
        let data = try await request(path: "/state/device/deviceinfo", method: "GET", authToken: authToken)
        let info = try VizioProtocolCodec.deviceInfo(from: data)
        reportedDeviceID = info.reportedDeviceID
        return info
    }

    func beginPairing(clientID: String) async throws -> VizioPairingChallenge {
        let body = try VizioProtocolCodec.beginPairing(deviceID: clientID)
        let data = try await request(path: "/pairing/start", method: "PUT", body: body)
        return try VizioProtocolCodec.pairingChallenge(from: data)
    }

    func finishPairing(
        clientID: String,
        challenge: VizioPairingChallenge,
        pin: String
    ) async throws -> String {
        let body = try VizioProtocolCodec.finishPairing(
            deviceID: clientID,
            challenge: challenge,
            pin: pin
        )
        let data = try await request(path: "/pairing/pair", method: "PUT", body: body)
        let token = try VizioProtocolCodec.authToken(from: data)
        authToken = token
        return token
    }

    func cancelPairing(clientID: String) async {
        guard let body = try? VizioProtocolCodec.cancelPairing(deviceID: clientID) else { return }
        _ = try? await request(path: "/pairing/cancel", method: "PUT", body: body)
    }

    func confirmDeviceAttestedPairing() throws -> Data {
        guard trustDelegate.confirmDeviceAttestedPairing(),
            let fingerprint = trustDelegate.candidateFingerprint
        else {
            throw VizioHTTPSClientError.missingCertificate
        }
        return fingerprint
    }

    func convenience(_ request: TVConvenienceRequest) async throws -> TVConvenienceResponse {
        guard let authToken, !isDisconnected else { throw VizioHTTPSClientError.notConnected }
        switch request {
        case .inputs:
            let data = try await self.request(
                path: VizioConvenienceCodec.inputsPath, method: "GET", authToken: authToken)
            let inputs = try VizioConvenienceCodec.inputs(from: data)
            didReadInputs = true
            return .inputs(inputs)
        case .selectInput(let input):
            let list = try await self.request(
                path: VizioConvenienceCodec.inputsPath, method: "GET", authToken: authToken)
            guard try VizioConvenienceCodec.inputs(from: list).contains(where: { $0.value == input.value })
            else { throw TVConvenienceError.unavailable }
            let current = try await self.request(
                path: VizioConvenienceCodec.currentInputPath, method: "GET", authToken: authToken)
            let hash = try VizioConvenienceCodec.currentInputHash(from: current)
            let body = try VizioConvenienceCodec.selectInput(input, currentHash: hash)
            _ = try await self.request(
                path: VizioConvenienceCodec.currentInputPath, method: "PUT", body: body, authToken: authToken)
            return .sent
        case .currentApp:
            let data = try await self.request(path: "/app/current", method: "GET", authToken: authToken)
            let app = try VizioConvenienceCodec.currentApp(from: data)
            didReadAppConfiguration = true
            return .currentApp(app)
        case .launch(let app):
            let body = try VizioConvenienceCodec.launch(app)
            _ = try await self.request(path: "/app/launch", method: "PUT", body: body, authToken: authToken)
            return .sent
        default: throw TVConvenienceError.unavailable
        }
    }

    func send(_ command: RemoteCommand) async throws {
        let body = try VizioProtocolCodec.remoteCommand(command)
        guard let authToken else {
            throw VizioHTTPSClientError.notConnected
        }
        _ = try await request(
            path: "/key_command/",
            method: "PUT",
            body: body,
            authToken: authToken
        )
    }

    func sendText(_ input: RemoteTextInput) async throws {
        throw TVDriverError.unsupportedTextInput
    }

    func checkConnection() async throws {
        guard let authToken else {
            throw VizioHTTPSClientError.notConnected
        }
        _ = try await deviceInfo(authToken: authToken)
    }

    func sessionObservation() async throws -> TVSessionObservation? {
        guard let authToken, let reportedDeviceID, !isDisconnected else { return nil }
        let powerState: TVPowerState
        do {
            let data = try await request(
                path: "/state/device/power_mode", method: "GET", authToken: authToken)
            powerState = VizioProtocolCodec.powerState(from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // An optional read failing never proves the screen is asleep or awake.
            powerState = .unknown
        }
        var capabilities = TVCapability.implemented(for: .vizio).subtracting([.inputSelection, .favoriteApps])
        if didReadInputs { capabilities.insert(.inputSelection) }
        if didReadAppConfiguration { capabilities.insert(.favoriteApps) }
        return TVSessionObservation(
            stableDeviceKey: "vizio:\(reportedDeviceID)", powerState: powerState,
            protocolReportedCapabilities: capabilities)
    }

    func disconnect() {
        guard !isDisconnected else { return }
        isDisconnected = true
        reportedDeviceID = nil
        session.invalidateAndCancel()
    }

    private func request(
        path: String,
        method: String,
        body: Data? = nil,
        authToken: String? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        guard !isDisconnected else {
            throw VizioHTTPSClientError.notConnected
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = address.rawValue
        components.port = Int(port)
        components.path = path
        guard let url = components.url else {
            throw VizioHTTPSClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authToken {
            request.setValue(authToken, forHTTPHeaderField: "AUTH")
        }

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard data.count <= Self.maximumResponseBytes,
                let response = response as? HTTPURLResponse,
                response.url?.scheme == "https",
                response.url?.host == address.rawValue,
                response.url?.port == Int(port),
                (200..<300).contains(response.statusCode)
            else {
                throw VizioHTTPSClientError.invalidResponse
            }
            try VizioProtocolCodec.requireSuccess(from: data)
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VizioProtocolError {
            throw error
        } catch let error as VizioHTTPSClientError {
            throw error
        } catch {
            switch trustDelegate.failure {
            case .certificateChanged:
                throw VizioHTTPSClientError.certificateChanged
            case .missingCertificate, .unexpectedEndpoint:
                throw VizioHTTPSClientError.missingCertificate
            case nil:
                throw VizioHTTPSClientError.unavailable
            }
        }
    }
}

enum VizioHTTPSClientError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case unavailable
    case invalidResponse
    case missingCertificate
    case certificateChanged
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Hafa Remote could not create a secure connection to that Vizio TV."
        case .unavailable:
            "The Vizio TV could not be reached. Check that it is on and on the same Wi-Fi network."
        case .invalidResponse:
            "The Vizio TV returned an unexpected response."
        case .missingCertificate:
            "Hafa Remote could not verify the Vizio TV's secure connection."
        case .certificateChanged:
            "This Vizio TV's security identity changed. Forget it before pairing again."
        case .notConnected:
            "Connect to the Vizio TV before sending a command."
        }
    }
}
