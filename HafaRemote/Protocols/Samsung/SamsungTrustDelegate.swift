import CryptoKit
import Foundation
import Security

/// Samsung TVs use a self-signed certificate. A new TV is trusted only as part of
/// the physical on-TV approval ceremony; reconnects must match the saved pin.
enum SamsungTrustMode: Equatable, Sendable {
    case firstPairingRequiringOnTVApproval
    case reconnect(expectedFingerprint: Data)
}

enum SamsungTrustFailure: Equatable, Sendable {
    case unexpectedEndpoint
    case missingCertificate
    case certificateChanged
}

enum SamsungTrustDecision: Equatable, Sendable {
    case accept
    case reject(SamsungTrustFailure)
}

/// Pure, deterministic policy used by the URLSession delegate. A second
/// certificate in the same first-pairing ceremony must match the first one.
struct SamsungTrustPolicy: Sendable {
    private let address: PrivateIPv4Address
    private let mode: SamsungTrustMode
    private(set) var candidateFingerprint: Data?

    init(address: PrivateIPv4Address, mode: SamsungTrustMode) {
        self.address = address
        self.mode = mode
    }

    mutating func evaluate(
        host: String,
        port: Int,
        presentedFingerprint: Data?
    ) -> SamsungTrustDecision {
        guard host == address.rawValue, port == 8002 else {
            return .reject(.unexpectedEndpoint)
        }
        guard let presentedFingerprint else {
            return .reject(.missingCertificate)
        }
        if case .reconnect(let expectedFingerprint) = mode,
            expectedFingerprint != presentedFingerprint
        {
            return .reject(.certificateChanged)
        }
        if let candidateFingerprint, candidateFingerprint != presentedFingerprint {
            return .reject(.certificateChanged)
        }

        candidateFingerprint = presentedFingerprint
        return .accept
    }
}

/// Restricts Samsung's self-signed TLS certificate exception to one explicit private host.
final class SamsungTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var policy: SamsungTrustPolicy
    private var storedFailure: SamsungTrustFailure?

    init(address: PrivateIPv4Address, mode: SamsungTrustMode) {
        policy = SamsungTrustPolicy(address: address, mode: mode)
    }

    /// This is only a candidate until the TV returns a token after physical approval.
    var candidateFingerprint: Data? {
        lock.withLock { policy.candidateFingerprint }
    }

    var failure: SamsungTrustFailure? {
        lock.withLock { storedFailure }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let trust = challenge.protectionSpace.serverTrust
        let fingerprint: Data?
        if let trust,
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        {
            fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        } else {
            fingerprint = nil
        }

        let decision = lock.withLock {
            let decision = policy.evaluate(
                host: challenge.protectionSpace.host,
                port: challenge.protectionSpace.port,
                presentedFingerprint: fingerprint
            )
            if case .reject(let failure) = decision {
                storedFailure = failure
            }
            return decision
        }
        guard decision == .accept, let trust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
