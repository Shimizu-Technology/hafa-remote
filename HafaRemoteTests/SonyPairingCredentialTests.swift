import Foundation
import Testing

@testable import HafaRemote

struct SonyPairingCredentialTests {
    @MainActor
    @Test("Reselecting a known Sony discovery alias selects its authenticated saved pin")
    func knownDiscoveryRowReusesSavedPin() async throws {
        let savedCredential = try SonyPairingCredential(certificateSHA256: Data(repeating: 45, count: 32))
        let alias = SonyBonjourCandidateMetadata(serviceName: "Synthetic Known Sony").reportedIdentifier
        let saved = SavedTV(
            brand: .sony, reportedDeviceID: savedCredential.reportedDeviceID,
            displayName: "Synthetic Known Sony",
            modelName: "Synthetic BRAVIA", firmwareVersion: nil, lastKnownAddress: "192.0.2.45",
            discoveryIdentifier: alias
        )
        let candidate = DiscoveredTV(
            brand: .sony, reportedIdentifier: alias, displayName: "Synthetic Known Sony",
            modelName: "Synthetic BRAVIA",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46"),
            controlPort: 6466
        )
        guard case .saved(let target) = SavedTVDiscoveryAssociation.resolve(candidate, savedTVs: [saved])
        else {
            Issue.record("The known discovery alias should be rebound to its saved identity")
            return
        }
        let store = KeychainSonyPairingCredentialStore(keychain: InMemorySonyPairingCredentialKeychain())
        try await store.save(savedCredential)
        #expect(target.expectedSavedDeviceID == savedCredential.reportedDeviceID)
        #expect(target.discoveryIdentifier == alias)
        #expect(target.address == candidate.address)
        #expect(
            try await SonySavedTargetCredentialLookup.credential(for: target, in: store) == savedCredential)
    }

    @Test("Sony advertisement hashes never select a saved certificate pin")
    func candidateHashCannotSelectSavedCredential() async throws {
        let saved = try SonyPairingCredential(certificateSHA256: Data(repeating: 42, count: 32))
        let store = KeychainSonyPairingCredentialStore(keychain: InMemorySonyPairingCredentialKeychain())
        try await store.save(saved)
        let candidate = TVConnectionTarget(
            brand: .sony,
            reportedDeviceID: saved.reportedDeviceID,
            address: try PrivateIPv4Address(documentationAddressForTesting: "203.0.113.42"),
            controlPort: 6466,
            discoveryIdentifier: saved.reportedDeviceID
        )

        #expect(try await SonySavedTargetCredentialLookup.credential(for: candidate, in: store) == nil)
        #expect(
            try await SonySavedTargetCredentialLookup.credential(
                for: candidate.expectingSavedIdentity(saved.reportedDeviceID), in: store
            ) == saved
        )
    }

    @Test("Sony rediscovery keeps the saved pin separate from the advertised alias")
    func aliasSelectsOnlyExpectedSavedPin() async throws {
        let selected = try SonyPairingCredential(certificateSHA256: Data(repeating: 43, count: 32))
        let other = try SonyPairingCredential(certificateSHA256: Data(repeating: 44, count: 32))
        let store = KeychainSonyPairingCredentialStore(keychain: InMemorySonyPairingCredentialKeychain())
        try await store.save(selected)
        try await store.save(other)
        let candidate = TVConnectionTarget(
            brand: .sony,
            reportedDeviceID: other.reportedDeviceID,
            address: try PrivateIPv4Address(documentationAddressForTesting: "203.0.113.43"),
            controlPort: 6466,
            expectedSavedDeviceID: selected.reportedDeviceID,
            discoveryIdentifier: other.reportedDeviceID
        )

        #expect(try await SonySavedTargetCredentialLookup.credential(for: candidate, in: store) == selected)
        #expect(try await store.credential(for: other.certificateSHA256) == other)
    }

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

    @Test("Removing a credential clears its persisted fingerprint")
    func removesCredential() async throws {
        let keychain = InMemorySonyPairingCredentialKeychain()
        let store = KeychainSonyPairingCredentialStore(keychain: keychain)
        let credential = try SonyPairingCredential(
            certificateSHA256: Data(repeating: 10, count: 32)
        )
        try await store.save(credential)

        try await store.remove(reportedDeviceID: credential.reportedDeviceID)

        #expect(try await store.credential(for: credential.certificateSHA256) == nil)
    }

    @Test("Corrupt credential data is discarded before reporting the error")
    func discardsCorruptCredential() async throws {
        let fingerprint = Data(repeating: 11, count: 32)
        let credential = try SonyPairingCredential(certificateSHA256: fingerprint)
        let keychain = InMemorySonyPairingCredentialKeychain()
        keychain.seed(Data("not-json".utf8), for: credential.reportedDeviceID)
        let store = KeychainSonyPairingCredentialStore(keychain: keychain)

        await #expect(throws: SonyKeychainError.invalidStoredCredential) {
            try await store.credential(for: fingerprint)
        }
        #expect(keychain.data(for: credential.reportedDeviceID) == nil)
    }

    @Test("A cleanup failure cannot hide the invalid stored credential state")
    func reportsInvalidCredentialWhenCleanupFails() async throws {
        let fingerprint = Data(repeating: 14, count: 32)
        let store = KeychainSonyPairingCredentialStore(
            keychain: RemovalFailingSonyPairingCredentialKeychain()
        )

        await #expect(throws: SonyKeychainError.invalidStoredCredential) {
            try await store.credential(for: fingerprint)
        }
    }

    @Test("A deleted corrupt record falls through to physical-TV pairing")
    func corruptRecordBecomesMissingCredential() async throws {
        let fingerprint = Data(repeating: 12, count: 32)
        let store = FailingSonyPairingCredentialStore(error: .invalidStoredCredential)

        #expect(
            try await SonyRecoverableCredentialLookup.credential(
                in: store,
                fingerprint: fingerprint
            ) == nil
        )
    }

    @Test("Credential lookup still propagates non-recoverable Keychain failures")
    func propagatesKeychainFailure() async {
        let failure = SonyKeychainError.readFailed(-50)
        let store = FailingSonyPairingCredentialStore(error: failure)

        await #expect(throws: failure) {
            try await SonyRecoverableCredentialLookup.credential(
                in: store,
                fingerprint: Data(repeating: 13, count: 32)
            )
        }
    }
}

private struct RemovalFailingSonyPairingCredentialKeychain: SonyPairingCredentialKeychain {
    func data(for account: String) -> Data? {
        Data("not-json".utf8)
    }

    func save(_ data: Data, for account: String) {}

    func remove(account: String) throws {
        throw SonyKeychainError.deleteFailed(-50)
    }
}

private actor FailingSonyPairingCredentialStore: SonyPairingCredentialStoring {
    private let error: SonyKeychainError

    init(error: SonyKeychainError) {
        self.error = error
    }

    func credential(for certificateSHA256: Data) throws -> SonyPairingCredential? {
        throw error
    }

    func save(_ credential: SonyPairingCredential) {}
    func remove(reportedDeviceID: String) {}
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

    func seed(_ data: Data, for account: String) {
        lock.withLock { values[account] = data }
    }
}
