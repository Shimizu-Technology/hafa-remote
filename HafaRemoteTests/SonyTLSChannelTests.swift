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
        #expect(SonyCertificateDisplayName.make(from: "AA-BB-CC-DD-EE-FF") == "Sony / Google TV")
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

    @Test("Disconnect reset drops every message from the prior TLS connection")
    func resetDropsPriorMessages() throws {
        let first = Data([1, 2, 3])
        let second = Data([4, 5, 6])
        var buffer = SonyTLSMessageBuffer()

        #expect(
            try buffer.append(SonyProtobuf.framed(first) + SonyProtobuf.framed(second)) == first
        )
        buffer.reset()

        #expect(buffer.next() == nil)
        #expect(try buffer.append(SonyProtobuf.framed(Data([7]))) == Data([7]))
        #expect(buffer.next() == nil)
    }

    @Test("Cancelling a TLS connection deadline preserves cancellation")
    func connectionDeadlinePreservesCancellation() async {
        let task = Task {
            try await SonyTLSConnectionDeadline.run(timeout: .seconds(30)) {
                try await Task.sleep(for: .seconds(30))
                return true
            }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
