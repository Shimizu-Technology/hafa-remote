import Foundation

/// The user-visible lifecycle of the one active television session.
enum RemoteSessionState: Equatable, Sendable {
    case idle
    case pairing
    case connecting
    case connected(PairedSamsungTV)
    case reconnecting(attempt: Int)
    case offline
    case denied
    case savedPairingRejected
    case certificateChanged
    case unsupported
    case failed(RemoteSessionFailure)
}

enum RemoteSessionOperation: String, Equatable, Sendable {
    case connect
    case send
    case disconnect
    case forgetPairing
}

enum RemoteSessionFailure: Equatable, Sendable {
    case timedOut(RemoteSessionOperation)
    case unexpected

    var message: String {
        switch self {
        case .timedOut(.connect):
            "The TV took too long to connect. Check that it is on and on the same Wi-Fi network."
        case .timedOut(.send):
            "The TV did not accept that command in time. Hafa Remote will reconnect."
        case .timedOut(.disconnect):
            "The previous TV connection took too long to close."
        case .timedOut(.forgetPairing):
            "Removing the saved pairing took too long. Try again."
        case .unexpected:
            "Hafa Remote could not complete that request. Try again."
        }
    }
}
