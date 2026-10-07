import Foundation

/// The user-visible lifecycle of the one active television session.
enum RemoteSessionState: Equatable, Sendable {
    case idle
    case pairing
    case connecting
    case connected(ConnectedTV)
    case reconnecting(attempt: Int)
    case offline
    case denied
    case savedPairingRejected
    case certificateChanged
    case unsupported
    case failed(RemoteSessionFailure)
}

/// Ownership is stamped by the producer before an update can enter a consumer queue.
/// These process-local values are never logged or exported as diagnostics.
struct RemoteSessionStateUpdate: Equatable, Sendable {
    let state: RemoteSessionState
    let requestID: UUID
    let generation: UUID
    let producedAt: ContinuousClock.Instant
}

enum TVRecoveryAction: Hashable, Sendable {
    case retryConnection
    case findTV
    case openSettings
}

extension RemoteSessionState {
    var recoveryActions: Set<TVRecoveryAction> {
        switch self {
        case .connected, .pairing: []
        case .certificateChanged, .savedPairingRejected, .denied: [.findTV, .openSettings]
        case .unsupported: [.findTV]
        case .idle, .connecting, .reconnecting, .offline, .failed:
            [.retryConnection, .findTV, .openSettings]
        }
    }
}

enum RemoteSessionOperation: String, Equatable, Sendable {
    case connect
    case send
    case healthCheck
    case disconnect
    case forgetPairing
}

enum RemoteSessionFailure: Equatable, Sendable {
    case timedOut(RemoteSessionOperation)
    case unrecognizedDeviceInfo(TVBrand)
    case unexpected
    case savedDeviceIdentityMismatch

    var message: String {
        switch self {
        case .timedOut(.connect):
            "The TV took too long to connect. Check that it is on and on the same Wi-Fi network."
        case .timedOut(.send):
            "The TV did not accept that command in time. Hafa Remote will reconnect."
        case .timedOut(.healthCheck):
            "The TV stopped responding. Hafa Remote will reconnect."
        case .timedOut(.disconnect):
            "The previous TV connection took too long to close."
        case .timedOut(.forgetPairing):
            "Removing the saved pairing took too long. Try again."
        case .unrecognizedDeviceInfo(let brand):
            "The \(brand.displayName) TV responded, but Hafa Remote could not read its device information. Update the TV software, then scan again."
        case .savedDeviceIdentityMismatch:
            "A different TV is using the remembered address. Find your TV again before connecting."
        case .unexpected:
            "Hafa Remote could not complete that request. Try again."
        }
    }
}
