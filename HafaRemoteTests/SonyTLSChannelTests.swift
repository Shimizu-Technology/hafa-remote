import Foundation
import Testing

@testable import HafaRemote

struct SonyTLSChannelTests {
    @Test("A selected pairing candidate pins one certificate for the whole connection")
    func pairingCandidateUsesOneCertificate() {
        let first = Data(repeating: 1, count: 32)
        let second = Data(repeating: 2, count: 32)
        var policy = SonyTLSTrustPolicy(mode: .selectedPairingCandidate)

        #expect(policy.evaluate(fingerprint: first) == .accept)
        #expect(policy.evaluate(fingerprint: first) == .accept)
        #expect(policy.evaluate(fingerprint: second) == .reject(.certificateChanged))
        #expect(policy.candidateFingerprint == first)
    }

    @Test("A reconnect accepts only the previously paired certificate")
    func reconnectRequiresSavedCertificate() {
        let saved = Data(repeating: 3, count: 32)
        let changed = Data(repeating: 4, count: 32)
        var accepted = SonyTLSTrustPolicy(mode: .reconnect(expectedCertificateSHA256: saved))
        var rejected = SonyTLSTrustPolicy(mode: .reconnect(expectedCertificateSHA256: saved))

        #expect(accepted.evaluate(fingerprint: saved) == .accept)
        #expect(rejected.evaluate(fingerprint: changed) == .reject(.certificateChanged))
        #expect(rejected.candidateFingerprint == nil)
    }
}
