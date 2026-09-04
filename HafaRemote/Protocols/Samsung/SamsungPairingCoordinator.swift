import Foundation

struct PairedSamsungTV: Equatable, Sendable {
    let address: PrivateIPv4Address
    let modelName: String
    let firmwareVersion: String?
}

protocol SamsungPairingCoordinating: Sendable {
    func pair(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () -> Void
    ) async throws -> PairedSamsungTV
    func sendSelect() async throws
    func forget(addressText: String) async throws
    func disconnect() async
}

/// Coordinates capability validation, secure connection, and credential persistence.
actor SamsungPairingCoordinator: SamsungPairingCoordinating {
    private let deviceInfoProvider: any SamsungDeviceInfoProviding
    private let credentialStore: any SamsungPairingCredentialStoring
    private let transport: any SamsungTransporting

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
        onWaitingForApproval: @escaping @Sendable @MainActor () -> Void = {}
    ) async throws -> PairedSamsungTV {
        let transport = transport
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let address = try PrivateIPv4Address(
                    addressText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let deviceInfo = try await deviceInfoProvider.fetchDeviceInfo(at: address)
                try Task.checkCancellation()
                guard deviceInfo.supportsTokenAuthentication else {
                    throw SamsungPairingCoordinatorError.unsupportedTokenAuthentication
                }

                let existingCredential = try await credentialStore.credential(for: address)
                try Task.checkCancellation()
                if existingCredential == nil {
                    await onWaitingForApproval()
                    try Task.checkCancellation()
                }
                let credential: SamsungPairingCredential
                do {
                    credential = try await transport.connect(to: address, using: existingCredential)
                } catch SamsungConnectionError.denied where existingCredential != nil {
                    throw SamsungPairingCoordinatorError.savedPairingRejected
                } catch SamsungConnectionError.certificateChanged {
                    throw SamsungPairingCoordinatorError.certificateChanged
                }
                try Task.checkCancellation()
                try await credentialStore.save(credential, for: address)

                return PairedSamsungTV(
                    address: address,
                    modelName: deviceInfo.modelName,
                    firmwareVersion: deviceInfo.firmwareVersion
                )
            } catch {
                guard Task.isCancelled || error is CancellationError else {
                    throw error
                }
                // The cancellation handler is best-effort and may run before a
                // suspension resumes. This ordered cleanup closes anything that
                // was created in that interval before pair exits.
                await transport.disconnect()
                throw CancellationError()
            }
        } onCancel: {
            Task {
                await transport.disconnect()
            }
        }
    }

    func sendSelect() async throws {
        try await transport.send(.select)
    }

    func forget(addressText: String) async throws {
        let address = try PrivateIPv4Address(addressText.trimmingCharacters(in: .whitespacesAndNewlines))
        await transport.disconnect()
        try await credentialStore.removeCredential(for: address)
    }

    func disconnect() async {
        await transport.disconnect()
    }
}

enum SamsungPairingCoordinatorError: LocalizedError, Equatable, Sendable {
    case unsupportedTokenAuthentication
    case certificateChanged
    case savedPairingRejected

    var canForgetPairing: Bool {
        self == .certificateChanged || self == .savedPairingRejected
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedTokenAuthentication:
            "This TV does not report the secure token pairing required by Hafa Remote."
        case .certificateChanged:
            "This TV's security identity changed. Remove its saved pairing before reconnecting."
        case .savedPairingRejected:
            "The TV no longer accepts its saved pairing. Remove it and approve Hafa Remote again."
        }
    }
}
