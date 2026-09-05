import CryptoKit
import Foundation
import Security

enum VizioTrustMode: Equatable, Sendable {
    case selectedPairingCandidate
    case reconnect(expectedFingerprint: Data)
}

enum VizioTrustFailure: Equatable, Sendable {
    case unexpectedEndpoint
    case missingCertificate
    case certificateChanged
}

enum VizioTrustDecision: Equatable, Sendable {
    case accept
    case reject(VizioTrustFailure)
}

struct VizioTrustPolicy: Sendable {
    private let address: PrivateIPv4Address
    private let port: UInt16
    private let mode: VizioTrustMode
    private(set) var candidateFingerprint: Data?

    init(address: PrivateIPv4Address, port: UInt16, mode: VizioTrustMode) {
        self.address = address
        self.port = port
        self.mode = mode
    }

    mutating func evaluate(
        host: String,
        port: Int,
        presentedFingerprint: Data?
    ) -> VizioTrustDecision {
        guard host == address.rawValue, port == Int(self.port) else {
            return .reject(.unexpectedEndpoint)
        }
        guard let presentedFingerprint else {
            return .reject(.missingCertificate)
        }
        if case .reconnect(let expected) = mode, expected != presentedFingerprint {
            return .reject(.certificateChanged)
        }
        if let candidateFingerprint, candidateFingerprint != presentedFingerprint {
            return .reject(.certificateChanged)
        }
        candidateFingerprint = presentedFingerprint
        return .accept
    }
}

final class VizioTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var policy: VizioTrustPolicy
    private var storedFailure: VizioTrustFailure?

    init(address: PrivateIPv4Address, port: UInt16, mode: VizioTrustMode) {
        policy = VizioTrustPolicy(address: address, port: port, mode: mode)
    }

    var candidateFingerprint: Data? {
        lock.withLock { policy.candidateFingerprint }
    }

    var failure: VizioTrustFailure? {
        lock.withLock { storedFailure }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let trust = challenge.protectionSpace.serverTrust
        let fingerprint: Data?
        if let trust,
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let certificate = chain.first
        {
            fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
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
