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
    private var observedPairingFingerprint: Data?
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
        switch mode {
        case .selectedPairingCandidate:
            if let observedPairingFingerprint,
                observedPairingFingerprint != presentedFingerprint
            {
                return .reject(.certificateChanged)
            }
            observedPairingFingerprint = presentedFingerprint
        case .reconnect(let expected):
            guard expected == presentedFingerprint else {
                return .reject(.certificateChanged)
            }
        }
        return .accept
    }

    mutating func confirmDeviceAttestedPairing() -> Bool {
        // The candidate certificate remains provisional until the selected physical TV
        // accepts the PIN that it displayed. Only the coordinator may call this after a
        // successful /pairing/pair response; failed and cancelled ceremonies persist nothing.
        guard case .selectedPairingCandidate = mode,
            let observedPairingFingerprint
        else {
            return false
        }
        candidateFingerprint = observedPairingFingerprint
        return true
    }
}

final class VizioTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expectedHost: String
    private let expectedPort: Int
    private var policy: VizioTrustPolicy
    private var storedFailure: VizioTrustFailure?

    init(address: PrivateIPv4Address, port: UInt16, mode: VizioTrustMode) {
        expectedHost = address.rawValue
        expectedPort = Int(port)
        policy = VizioTrustPolicy(address: address, port: port, mode: mode)
    }

    var candidateFingerprint: Data? {
        lock.withLock { policy.candidateFingerprint }
    }

    var failure: VizioTrustFailure? {
        lock.withLock { storedFailure }
    }

    override var description: String {
        "VizioTrustDelegate(redacted)"
    }

    func confirmDeviceAttestedPairing() -> Bool {
        lock.withLock {
            policy.confirmDeviceAttestedPairing()
        }
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme == "https",
            request.url?.host == expectedHost,
            request.url?.port == expectedPort
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
