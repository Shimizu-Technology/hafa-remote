import Foundation

/// The compiled product is independent of runtime metadata and submission approval.
enum TVBuildFlavor: String, Sendable {
    case internalTesting = "internal"
    case samsungPublic = "public"

    static var compiled: Self {
        #if HAFA_PUBLIC_BUILD
            .samsungPublic
        #else
            .internalTesting
        #endif
    }

    func validatesAudience(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value == rawValue
    }

    static var isConfigured: Bool {
        compiled.validatesAudience(Bundle.main.object(forInfoDictionaryKey: "HafaDistributionAudience"))
    }
}

/// No transport or credential store is constructed for mismatched build metadata.
actor DisabledRemoteSessionDriver: RemoteSessionDriving {
    nonisolated func supports(_ brand: TVBrand) -> Bool { false }
    func connect(addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void)
        async throws -> ConnectedTV
    {
        throw TVSessionDriverError.unsupportedBrand
    }
    func send(_ command: RemoteCommand) async throws { throw TVSessionDriverError.unsupportedBrand }
    func forget(addressText: String) async throws { throw RemoteCredentialRemovalError.unsupported }
    func disconnect() async {}
}

@MainActor
final class DisabledTVDiscoveryBackend: TVDiscoveryBackend {
    func start(eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void) {
        eventHandler(.failed)
    }
    func stop() {}
}

enum TVSessionDriverError: LocalizedError, Equatable, Sendable {
    case unsupportedBrand
    case notConnected
    case pairingCodeNotExpected
    case pairingCodeAlreadyRequested
    case missingStableIdentity

    var errorDescription: String? {
        switch self {
        case .unsupportedBrand:
            "That TV brand is not enabled in this build."
        case .notConnected:
            "Connect to a TV before sending a command."
        case .pairingCodeNotExpected:
            "The TV is not waiting for a pairing code."
        case .pairingCodeAlreadyRequested:
            "A TV pairing code is already being requested."
        case .missingStableIdentity:
            "Find the TV again before removing its saved pairing."
        }
    }
}

#if !HAFA_PUBLIC_BUILD
    typealias MultiBrandSessionDriverError = TVSessionDriverError
#endif
