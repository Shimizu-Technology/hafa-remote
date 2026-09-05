import Foundation
import Testing

@testable import HafaRemote

struct SonyPairingCredentialTests {
    @Test("A Sony certificate fingerprint round-trips through its stable device ID")
    func roundTripsStableIdentity() throws {
        let fingerprint = Data((0..<32).map(UInt8.init))
        let credential = try SonyPairingCredential(certificateSHA256: fingerprint)

        #expect(credential.reportedDeviceID.count == 64)
        #expect(try SonyPairingCredential(reportedDeviceID: credential.reportedDeviceID) == credential)
    }

    @Test("Malformed Sony fingerprints never become credential identities")
    func rejectsMalformedIdentity() {
        #expect(throws: SonyPairingCredentialError.invalidFingerprint) {
            try SonyPairingCredential(certificateSHA256: Data(repeating: 1, count: 31))
        }
        #expect(throws: SonyPairingCredentialError.invalidFingerprint) {
            try SonyPairingCredential(reportedDeviceID: String(repeating: "z", count: 64))
        }
    }
}
