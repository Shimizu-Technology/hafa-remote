import Foundation

typealias VizioPINProvider = @Sendable @MainActor (VizioPairingChallenge) async throws -> String
typealias VizioHTTPClientFactory =
    @Sendable (
        _ address: PrivateIPv4Address,
        _ port: UInt16,
        _ trustMode: VizioTrustMode,
        _ authToken: String?
    ) throws -> any VizioHTTPClienting

protocol VizioPairingCoordinating: TVDriver {
    func pair(target: TVConnectionTarget, pinProvider: @escaping VizioPINProvider) async throws
        -> ConnectedTV
    func forget(reportedDeviceID: String) async throws
    /// Deletes a saved Vizio token without requiring SmartCast client teardown.
    func removeCredential(reportedDeviceID: String) async throws
}

extension VizioPairingCoordinating {
    /// Refuses to treat a potentially destructive legacy forget as credential-only.
    func removeCredential(reportedDeviceID: String) async throws {
        throw RemoteCredentialRemovalError.unsupported
    }
}

actor VizioPairingCoordinator: VizioPairingCoordinating {
    private let credentialStore: any VizioPairingCredentialStoring
    private let makeClient: VizioHTTPClientFactory
    private var activeClient: (any VizioHTTPClienting)?
    private var connectionAttemptID: UUID?

    init(
        credentialStore: any VizioPairingCredentialStoring,
        makeClient: @escaping VizioHTTPClientFactory = { address, port, trustMode, authToken in
            try VizioHTTPSClient(
                address: address,
                port: port,
                trustMode: trustMode,
                authToken: authToken
            )
        }
    ) {
        self.credentialStore = credentialStore
        self.makeClient = makeClient
    }

    func pair(
        target: TVConnectionTarget,
        pinProvider: @escaping VizioPINProvider
    ) async throws -> ConnectedTV {
        guard connectionAttemptID == nil else {
            throw VizioPairingCoordinatorError.pairingInProgress
        }
        guard target.brand == .vizio, let port = target.controlPort else {
            throw VizioPairingCoordinatorError.invalidTarget
        }

        let attemptID = UUID()
        connectionAttemptID = attemptID
        await activeClient?.disconnect()
        activeClient = nil

        var savedIdentity: VizioPairingIdentity?
        var savedNewCredential = false
        let cleanup = VizioPairingAttemptCleanup()

        defer {
            if connectionAttemptID == attemptID {
                connectionAttemptID = nil
            }
        }

        return try await withTaskCancellationHandler {
            do {
                let provisional = try makeClient(
                    target.address,
                    port,
                    .selectedPairingCandidate,
                    nil
                )
                await cleanup.update(client: provisional)
                let provisionalInfo: VizioDeviceInfo
                do {
                    provisionalInfo = try await provisional.deviceInfo(authToken: nil)
                } catch VizioProtocolError.invalidResponse {
                    throw VizioPairingCoordinatorError.unrecognizedDeviceInfo
                }
                try Task.checkCancellation()
                let identity = try VizioPairingIdentity(
                    reportedDeviceID: provisionalInfo.reportedDeviceID
                )
                savedIdentity = identity

                let existingCredential = try await credentialStore.credential(for: identity)
                let connectedClient: any VizioHTTPClienting
                let confirmedInfo: VizioDeviceInfo
                if let existingCredential {
                    await provisional.disconnect()
                    let pinned = try makeClient(
                        target.address,
                        port,
                        .reconnect(expectedFingerprint: existingCredential.certificateSHA256),
                        existingCredential.authToken
                    )
                    await cleanup.update(client: pinned)
                    do {
                        confirmedInfo = try await pinned.deviceInfo(
                            authToken: existingCredential.authToken
                        )
                    } catch VizioProtocolError.rejected {
                        throw VizioPairingCoordinatorError.savedPairingRejected
                    } catch VizioProtocolError.invalidResponse {
                        throw VizioPairingCoordinatorError.unrecognizedDeviceInfo
                    }
                    guard confirmedInfo.reportedDeviceID == identity.reportedDeviceID else {
                        throw VizioPairingCoordinatorError.deviceIdentityChanged
                    }
                    connectedClient = pinned
                } else {
                    let clientID = UUID().uuidString.lowercased()
                    await cleanup.update(pairingClientID: clientID)
                    var stateMachine = VizioPairingStateMachine()
                    let challenge = try await provisional.beginPairing(clientID: clientID)
                    try stateMachine.apply(.receivedChallenge(challenge))
                    let pin = try await pinProvider(challenge)
                    try Task.checkCancellation()
                    let authToken: String
                    do {
                        authToken = try await provisional.finishPairing(
                            clientID: clientID,
                            challenge: challenge,
                            pin: pin
                        )
                    } catch VizioProtocolError.rejected {
                        try? stateMachine.apply(.failed)
                        throw VizioPairingCoordinatorError.pinRejected
                    }
                    try stateMachine.apply(.acceptedPIN)
                    let fingerprint = try await provisional.confirmDeviceAttestedPairing()
                    let credential = try VizioPairingCredential(
                        authToken: authToken,
                        certificateSHA256: fingerprint,
                        clientID: clientID
                    )
                    try await credentialStore.save(credential, for: identity)
                    savedNewCredential = true
                    confirmedInfo = provisionalInfo
                    connectedClient = provisional
                }

                try Task.checkCancellation()
                guard connectionAttemptID == attemptID else {
                    throw CancellationError()
                }
                activeClient = connectedClient
                await cleanup.release()
                return ConnectedTV(
                    brand: .vizio,
                    reportedDeviceID: confirmedInfo.reportedDeviceID,
                    address: target.address,
                    controlPort: port,
                    displayName: confirmedInfo.displayName,
                    modelName: confirmedInfo.modelName,
                    firmwareVersion: confirmedInfo.firmwareVersion
                )
            } catch {
                await cleanup.cancel()
                if savedNewCredential, let savedIdentity {
                    try? await credentialStore.remove(for: savedIdentity)
                }
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                if let clientError = error as? VizioHTTPSClientError,
                    clientError == .certificateChanged
                {
                    throw VizioPairingCoordinatorError.certificateChanged
                }
                throw error
            }
        } onCancel: {
            Task {
                await cleanup.cancel()
            }
        }
    }

    func send(_ command: RemoteCommand) async throws {
        guard let activeClient else {
            throw VizioHTTPSClientError.notConnected
        }
        try await activeClient.send(command)
    }

    func sendText(_ input: RemoteTextInput) async throws {
        throw TVDriverError.unsupportedTextInput
    }

    func forget(reportedDeviceID: String) async throws {
        try Task.checkCancellation()
        await disconnect()
        try await removeCredential(reportedDeviceID: reportedDeviceID)
    }

    /// Deletes the saved Vizio auth token without closing another active session.
    func removeCredential(reportedDeviceID: String) async throws {
        try Task.checkCancellation()
        let identity = try VizioPairingIdentity(reportedDeviceID: reportedDeviceID)
        try await credentialStore.remove(for: identity)
    }

    func disconnect() async {
        connectionAttemptID = nil
        await activeClient?.disconnect()
        activeClient = nil
    }
}

private actor VizioPairingAttemptCleanup {
    private var client: (any VizioHTTPClienting)?
    private var pairingClientID: String?
    private var cancellationRequested = false
    private var isReleased = false

    func update(client: any VizioHTTPClienting) async {
        guard !isReleased else { return }
        if cancellationRequested {
            await client.disconnect()
            return
        }
        self.client = client
    }

    func update(pairingClientID: String) async {
        guard !isReleased else { return }
        if cancellationRequested {
            await client?.cancelPairing(clientID: pairingClientID)
            await client?.disconnect()
            client = nil
            return
        }
        self.pairingClientID = pairingClientID
    }

    func cancel() async {
        guard !isReleased else { return }
        cancellationRequested = true
        if let pairingClientID {
            await client?.cancelPairing(clientID: pairingClientID)
        }
        await client?.disconnect()
        client = nil
        pairingClientID = nil
    }

    func release() {
        isReleased = true
        client = nil
        pairingClientID = nil
    }
}

enum VizioPairingCoordinatorError: LocalizedError, Equatable, Sendable {
    case invalidTarget
    case pairingInProgress
    case savedPairingRejected
    case pinRejected
    case certificateChanged
    case deviceIdentityChanged
    case unrecognizedDeviceInfo

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "The selected device is not a supported Vizio TV."
        case .pairingInProgress:
            "A Vizio TV connection is already in progress."
        case .savedPairingRejected:
            "The Vizio TV no longer accepts its saved pairing. Forget it and pair again."
        case .pinRejected:
            "That PIN was not accepted. Check the Vizio TV and try again."
        case .certificateChanged:
            "This Vizio TV's security identity changed. Forget it before pairing again."
        case .deviceIdentityChanged:
            "The Vizio TV identity changed during connection. Try discovering it again."
        case .unrecognizedDeviceInfo:
            "The Vizio TV responded, but Hafa Remote could not read its device information. Update the TV software, then scan again."
        }
    }
}
