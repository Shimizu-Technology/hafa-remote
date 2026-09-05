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

    @Test("The credential store persists a paired certificate fingerprint")
    func persistsCredential() async throws {
        let keychain = InMemorySonyPairingCredentialKeychain()
        let store = KeychainSonyPairingCredentialStore(keychain: keychain)
        let credential = try SonyPairingCredential(
            certificateSHA256: Data(repeating: 7, count: 32)
        )

        try await store.save(credential)

        #expect(try await store.credential(for: credential.certificateSHA256) == credential)
    }

    @Test("The credential store returns nil for an unpaired certificate")
    func returnsNilForUnknownFingerprint() async throws {
        let store = KeychainSonyPairingCredentialStore(
            keychain: InMemorySonyPairingCredentialKeychain()
        )

        #expect(
            try await store.credential(for: Data(repeating: 9, count: 32)) == nil
        )
    }
}

private final class InMemorySonyPairingCredentialKeychain:
    SonyPairingCredentialKeychain,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for account: String) -> Data? {
        lock.withLock { values[account] }
    }

    func save(_ data: Data, for account: String) {
        lock.withLock { values[account] = data }
    }

    func remove(account: String) {
        lock.withLock { values[account] = nil }
    }
}
