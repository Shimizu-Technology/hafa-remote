import Foundation
import Testing

@testable import HafaRemote

struct SonyTLSChannelTests {
    @Test("Certificate subjects expose the TV name without its network identifier")
    func sanitizesCertificateDisplayName() {
        let subject = "atvremote/bravia/bravia/Living Room Sony/AA:BB:CC:DD:EE:FF"

        #expect(SonyCertificateDisplayName.make(from: subject) == "Living Room Sony")
        #expect(SonyCertificateDisplayName.make(from: nil) == "Sony / Google TV")
        #expect(!SonyCertificateDisplayName.make(from: subject).contains("AA:BB"))
    }

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
