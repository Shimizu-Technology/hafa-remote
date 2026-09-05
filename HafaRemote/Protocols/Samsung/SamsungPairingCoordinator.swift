import Foundation

protocol SamsungPairingCoordinating: Sendable {
    func pair(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV
    func send(_ command: RemoteCommand) async throws
    func sendText(_ input: RemoteTextInput) async throws
    func forget(addressText: String) async throws
    func forget(addressText: String, reportedDeviceID: String?) async throws
    func disconnect() async
}

extension SamsungPairingCoordinating {
    func sendSelect() async throws {
        try await send(.select)
    }

    func sendText(_ input: RemoteTextInput) async throws {
        throw TVDriverError.unsupportedTextInput
    }

    func forget(addressText: String, reportedDeviceID: String?) async throws {
        try await forget(addressText: addressText)
    }
}

/// Coordinates capability validation, secure connection, and credential persistence.
actor SamsungPairingCoordinator: SamsungPairingCoordinating {
    private let deviceInfoProvider: any SamsungDeviceInfoProviding
    private let credentialStore: any SamsungPairingCredentialStoring
    private let transport: any SamsungTransporting
    private var activeAttemptID: SamsungConnectionAttemptID?
    private var mostRecentIdentityByAddress: [PrivateIPv4Address: SamsungPairingCredentialIdentity] = [:]

    init(
        deviceInfoProvider: any SamsungDeviceInfoProviding,
        credentialStore: any SamsungPairingCredentialStoring,
        transport: any SamsungTransporting
    ) {
        self.deviceInfoProvider = deviceInfoProvider
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func pair(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void = {}
    ) async throws -> ConnectedTV {
        guard activeAttemptID == nil else {
            throw SamsungPairingCoordinatorError.pairingInProgress
        }
        let attemptID = SamsungConnectionAttemptID()
        activeAttemptID = attemptID
        defer {
            if activeAttemptID == attemptID {
                activeAttemptID = nil
            }
        }

        let transport = transport
        var attemptedAddress: PrivateIPv4Address?
        var attemptedIdentity: SamsungPairingCredentialIdentity?
        var previousCredential: SamsungPairingCredential?
        var credentialSaveStarted = false
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let address = try PrivateIPv4Address(
                    addressText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                attemptedAddress = address
                let deviceInfo = try await deviceInfoProvider.fetchDeviceInfo(at: address)
                try Task.checkCancellation()
                guard deviceInfo.supportsTokenAuthentication else {
                    throw SamsungPairingCoordinatorError.unsupportedTokenAuthentication
                }
                let identity = try SamsungPairingCredentialIdentity(
                    reportedDeviceID: deviceInfo.reportedDeviceID
                )
                attemptedIdentity = identity
                mostRecentIdentityByAddress[address] = identity

                let existingCredential = try await credentialStore.credential(
                    for: identity,
                    discardingLegacyCredentialFor: address
                )
                previousCredential = existingCredential
                try Task.checkCancellation()
                if existingCredential == nil {
                    await onWaitingForApproval()
                    try Task.checkCancellation()
                }
                let credential: SamsungPairingCredential
                do {
                    credential = try await transport.connect(
                        to: address,
                        using: existingCredential,
                        attemptID: attemptID
                    )
                } catch SamsungConnectionError.denied where existingCredential != nil {
                    throw SamsungPairingCoordinatorError.savedPairingRejected
                } catch SamsungConnectionError.certificateChanged {
                    throw SamsungPairingCoordinatorError.certificateChanged
                }
                try Task.checkCancellation()
                credentialSaveStarted = true
                try await credentialStore.save(credential, for: identity)
                try Task.checkCancellation()

                return ConnectedTV(
                    brand: .samsung,
                    reportedDeviceID: deviceInfo.reportedDeviceID,
                    address: address,
                    modelName: deviceInfo.modelName,
                    firmwareVersion: deviceInfo.firmwareVersion,
                    networkConnection: deviceInfo.networkConnection,
                    macAddress: deviceInfo.macAddress
                )
            } catch {
                guard Task.isCancelled || error is CancellationError else {
                    await transport.disconnect(attemptID: attemptID)
                    throw error
                }
                // The cancellation handler is best-effort and may run before a
                // suspension resumes. This ordered cleanup closes anything that
                // was created in that interval before pair exits.
                await transport.disconnect(attemptID: attemptID)
                if credentialSaveStarted, let attemptedAddress, let attemptedIdentity {
                    if let previousCredential {
                        try? await credentialStore.save(previousCredential, for: attemptedIdentity)
                    } else {
                        try? await credentialStore.removeCredential(
                            for: attemptedIdentity,
                            legacyAddress: attemptedAddress
                        )
                    }
                }
                throw CancellationError()
            }
        } onCancel: {
            Task {
                await transport.disconnect(attemptID: attemptID)
            }
        }
    }

    func send(_ command: RemoteCommand) async throws {
        try await transport.send(command)
    }

    func sendText(_ input: RemoteTextInput) async throws {
        try await transport.sendText(input)
    }

    func forget(addressText: String) async throws {
        try await forget(addressText: addressText, reportedDeviceID: nil)
    }

    func forget(addressText: String, reportedDeviceID: String?) async throws {
        let address = try PrivateIPv4Address(addressText.trimmingCharacters(in: .whitespacesAndNewlines))
        await transport.disconnect()
        let persistedIdentity = try reportedDeviceID.map {
            try SamsungPairingCredentialIdentity(reportedDeviceID: $0)
        }
        if let identity = persistedIdentity ?? mostRecentIdentityByAddress[address] {
            try await credentialStore.removeCredential(for: identity, legacyAddress: address)
            mostRecentIdentityByAddress[address] = nil
        } else {
            // No stable identity is available, so the store may only discard the
            // unsafe address-keyed alpha credential. A discovery request is never
            // required to forget locally held authentication material.
            try await credentialStore.removeLegacyCredential(for: address)
        }
    }

    func disconnect() async {
        await transport.disconnect()
    }
}

enum SamsungPairingCoordinatorError: LocalizedError, Equatable, Sendable {
    case pairingInProgress
    case unsupportedTokenAuthentication
    case certificateChanged
    case savedPairingRejected

    var canForgetPairing: Bool {
        self == .certificateChanged || self == .savedPairingRejected
    }

    var errorDescription: String? {
        switch self {
        case .pairingInProgress:
            "A TV connection is already in progress."
        case .unsupportedTokenAuthentication:
            "This TV does not report the secure token pairing required by Hafa Remote."
        case .certificateChanged:
            "This TV's security identity changed. Remove its saved pairing before reconnecting."
        case .savedPairingRejected:
            "The TV no longer accepts its saved pairing. Remove it and approve Hafa Remote again."
        }
    }
}
