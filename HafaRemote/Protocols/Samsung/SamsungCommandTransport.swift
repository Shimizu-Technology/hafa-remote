import Foundation

struct SamsungConnectionAttemptID: Hashable, Sendable {
    private let rawValue = UUID()
}

protocol SamsungTransporting: TVDriver {
    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?,
        attemptID: SamsungConnectionAttemptID
    ) async throws -> SamsungPairingCredential

    func disconnect(attemptID: SamsungConnectionAttemptID) async
}

extension SamsungTransporting {
    func disconnect(attemptID: SamsungConnectionAttemptID) async {
        await disconnect()
    }
}

/// Owns the single secure Samsung WebSocket and its serialized command stream.
actor SamsungCommandTransport: SamsungTransporting {
    private var session: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var attempts = SamsungConnectionAttemptTracker()
    private let commandSerializer = SamsungCommandSerializer()
    private let pairingTimeout: Duration

    init(pairingTimeout: Duration = .seconds(45)) {
        self.pairingTimeout = pairingTimeout
    }

    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?,
        attemptID: SamsungConnectionAttemptID
    ) async throws -> SamsungPairingCredential {
        try Task.checkCancellation()
        disconnectCurrentSocket()
        attempts.begin(attemptID)

        var attemptSession: URLSession?
        var attemptSocket: URLSessionWebSocketTask?
        var attemptDelegate: SamsungTrustDelegate?

        do {
            let trustMode: SamsungTrustMode
            if let credential {
                trustMode = .reconnect(expectedFingerprint: credential.certificateSHA256)
            } else {
                trustMode = .firstPairingRequiringOnTVApproval
            }
            let delegate = SamsungTrustDelegate(address: address, mode: trustMode)
            attemptDelegate = delegate
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            let endpoint = try SamsungWebSocketURLBuilder.url(
                address: address,
                token: credential?.token
            )

            // The explicit pairing timeout below must not shorten the lifetime
            // of the established remote-control socket.
            try Task.checkCancellation()
            let createdSession = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            let createdSocket = createdSession.webSocketTask(with: endpoint)
            attemptSession = createdSession
            attemptSocket = createdSocket
            session = createdSession
            webSocket = createdSocket
            createdSocket.resume()

            let token = try await waitForPairingToken(
                on: createdSocket,
                trustMode: trustMode,
                existingCredential: credential
            )
            guard attempts.isCurrent(attemptID) else {
                throw SamsungConnectionError.unavailable
            }
            guard let fingerprint = delegate.candidateFingerprint else {
                throw SamsungConnectionError.missingCertificate
            }
            return try SamsungPairingCredential(
                token: token,
                certificateSHA256: fingerprint
            )
        } catch {
            let trustFailure = attemptDelegate?.failure
            if attempts.finishIfCurrent(attemptID) {
                disconnectCurrentSocket()
            } else {
                // This suspended attempt was replaced. Close only its captured
                // resources so it cannot tear down the newer active socket.
                attemptSocket?.cancel(with: .goingAway, reason: nil)
                attemptSession?.invalidateAndCancel()
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

    func disconnect(attemptID: SamsungConnectionAttemptID) {
        guard attempts.isCurrent(attemptID) else { return }
        disconnectCurrentSocket()
    }

    private func waitForPairingToken(
        on webSocket: URLSessionWebSocketTask,
        trustMode: SamsungTrustMode,
        existingCredential: SamsungPairingCredential?
    ) async throws -> String {
        let timeout = pairingTimeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for _ in 0..<10 {
                    let message = try await webSocket.receive()
                    switch try SamsungProtocolCodec.event(from: message) {
                    case .connected(let receivedToken):
                        switch trustMode {
                        case .firstPairingRequiringOnTVApproval:
                            // The returned token proves the user completed Samsung's
                            // physical Allow prompt before the candidate pin is saved.
                            guard let receivedToken, !receivedToken.isEmpty else {
                                throw SamsungConnectionError.missingPairingToken
                            }
                            return receivedToken
                        case .reconnect:
                            guard let token = receivedToken ?? existingCredential?.token,
                                !token.isEmpty
                            else {
                                throw SamsungConnectionError.missingPairingToken
                            }
                            return token
                        }
                    case .unauthorized:
                        throw SamsungConnectionError.denied
                    case .ignored:
                        continue
                    }
                }
                throw SamsungConnectionError.invalidResponse
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                webSocket.cancel(with: .goingAway, reason: nil)
                throw SamsungConnectionError.pairingTimedOut
            }

            guard let token = try await group.next() else {
                throw SamsungConnectionError.invalidResponse
            }
            group.cancelAll()
            return token
        }
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
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []

    func perform(_ operation: @Sendable () async throws -> Void) async throws {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isExecuting {
            isExecuting = true
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
        guard acquired else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func release() {
        if waiters.isEmpty {
            isExecuting = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// Makes actor reentrancy explicit: cleanup from a suspended attempt can only
/// invalidate the generation that created it.
struct SamsungConnectionAttemptTracker: Sendable {
    private var activeID: SamsungConnectionAttemptID?

    mutating func begin(_ attemptID: SamsungConnectionAttemptID) {
        activeID = attemptID
    }

    func isCurrent(_ attemptID: SamsungConnectionAttemptID) -> Bool {
        activeID == attemptID
    }

    mutating func finishIfCurrent(_ attemptID: SamsungConnectionAttemptID) -> Bool {
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
    case pairingTimedOut
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
        case .pairingTimedOut:
            "TV approval took too long. Try again and choose Allow on the TV."
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
