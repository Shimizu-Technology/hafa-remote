import Foundation

protocol SamsungTransporting: TVDriver {
    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?
    ) async throws -> SamsungPairingCredential
}

/// Owns the single secure Samsung WebSocket and its serialized command stream.
actor SamsungCommandTransport: SamsungTransporting {
    private var session: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var attempts = SamsungConnectionAttemptTracker()
    private let commandSerializer = SamsungCommandSerializer()

    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?
    ) async throws -> SamsungPairingCredential {
        try Task.checkCancellation()
        disconnectCurrentSocket()
        let attemptID = attempts.begin()

        let trustMode: SamsungTrustMode
        if let credential {
            trustMode = .reconnect(expectedFingerprint: credential.certificateSHA256)
        } else {
            trustMode = .firstPairingRequiringOnTVApproval
        }
        let delegate = SamsungTrustDelegate(
            address: address,
            mode: trustMode
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let endpoint = try SamsungWebSocketURLBuilder.url(address: address, token: credential?.token)
        let webSocket = session.webSocketTask(with: endpoint)
        self.session = session
        self.webSocket = webSocket
        try Task.checkCancellation()
        webSocket.resume()

        do {
            for _ in 0..<10 {
                let message = try await webSocket.receive()
                switch try SamsungProtocolCodec.event(from: message) {
                case .connected(let receivedToken):
                    guard attempts.isCurrent(attemptID) else {
                        throw SamsungConnectionError.unavailable
                    }
                    guard let fingerprint = delegate.candidateFingerprint else {
                        throw SamsungConnectionError.missingCertificate
                    }
                    let token: String
                    switch trustMode {
                    case .firstPairingRequiringOnTVApproval:
                        // The returned token proves the user completed Samsung's
                        // physical Allow prompt before the candidate pin is saved.
                        guard let receivedToken else {
                            throw SamsungConnectionError.missingPairingToken
                        }
                        token = receivedToken
                    case .reconnect:
                        guard let reconnectToken = receivedToken ?? credential?.token else {
                            throw SamsungConnectionError.missingPairingToken
                        }
                        token = reconnectToken
                    }
                    guard !token.isEmpty else {
                        throw SamsungConnectionError.missingPairingToken
                    }
                    return try SamsungPairingCredential(
                        token: token,
                        certificateSHA256: fingerprint
                    )
                case .unauthorized:
                    throw SamsungConnectionError.denied
                case .ignored:
                    continue
                }
            }
            throw SamsungConnectionError.invalidResponse
        } catch {
            let trustFailure = delegate.failure
            if attempts.finishIfCurrent(attemptID) {
                disconnectCurrentSocket()
            } else {
                // This suspended attempt was replaced. Close only its captured
                // resources so it cannot tear down the newer active socket.
                webSocket.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            if trustFailure == .certificateChanged {
                throw SamsungConnectionError.certificateChanged
            }
            if trustFailure == .missingCertificate || trustFailure == .unexpectedEndpoint {
                throw SamsungConnectionError.missingCertificate
            }
            if let connectionError = error as? SamsungConnectionError {
                throw connectionError
            }
            throw SamsungConnectionError.unavailable
        }
    }

    func send(_ command: RemoteCommand) async throws {
        guard let webSocket else {
            throw SamsungConnectionError.notConnected
        }
        let message = try SamsungProtocolCodec.remoteMessage(for: command)
        do {
            try await commandSerializer.perform {
                try await webSocket.send(message)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SamsungConnectionError.unavailable
        }
    }

    func disconnect() {
        disconnectCurrentSocket()
    }

    private func disconnectCurrentSocket() {
        attempts.invalidate()
        webSocket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        webSocket = nil
        session = nil
    }
}

/// Provides a FIFO, cancellation-aware boundary around WebSocket writes.
actor SamsungCommandSerializer {
    private var isExecuting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform(_ operation: @Sendable () async throws -> Void) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await operation()
    }

    private func acquire() async {
        if !isExecuting {
            isExecuting = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isExecuting = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Makes actor reentrancy explicit: cleanup from a suspended attempt can only
/// invalidate the generation that created it.
struct SamsungConnectionAttemptTracker: Sendable {
    private var nextID: UInt64 = 0
    private var activeID: UInt64?

    mutating func begin() -> UInt64 {
        nextID &+= 1
        activeID = nextID
        return nextID
    }

    func isCurrent(_ attemptID: UInt64) -> Bool {
        activeID == attemptID
    }

    mutating func finishIfCurrent(_ attemptID: UInt64) -> Bool {
        guard isCurrent(attemptID) else { return false }
        activeID = nil
        return true
    }

    mutating func invalidate() {
        activeID = nil
    }
}

enum SamsungConnectionError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case unavailable
    case denied
    case invalidResponse
    case missingCertificate
    case certificateChanged
    case missingPairingToken
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Hafa Remote could not create a secure connection for that address."
        case .unavailable:
            "The secure TV connection could not be completed. Check that the TV is on and on the same Wi-Fi network."
        case .denied:
            "The TV did not approve Hafa Remote. Try again and choose Allow on the TV."
        case .invalidResponse:
            "The TV returned an unexpected pairing response."
        case .missingCertificate:
            "Hafa Remote could not verify the TV's secure connection."
        case .certificateChanged:
            "The TV's security identity changed. Forget this TV before pairing it again."
        case .missingPairingToken:
            "The TV connected without providing a pairing token."
        case .notConnected:
            "Connect to the TV before sending a command."
        }
    }
}
