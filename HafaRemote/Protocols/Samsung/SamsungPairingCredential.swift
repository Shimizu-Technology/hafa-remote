import CryptoKit
import Foundation
import Security

/// The minimum credential needed to reconnect to one approved television safely.
struct SamsungPairingCredential: Codable, CustomStringConvertible, Equatable, Sendable {
    let token: String
    let certificateSHA256: Data

    init(token: String, certificateSHA256: Data) throws {
        guard !token.isEmpty,
            token.utf8.count <= 512,
            token.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw SamsungPairingCredentialError.invalidToken
        }
        guard certificateSHA256.count == 32 else {
            throw SamsungPairingCredentialError.invalidCertificateFingerprint
        }

        self.token = token
        self.certificateSHA256 = certificateSHA256
    }

    var description: String {
        "SamsungPairingCredential(redacted)"
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case certificateSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            token: container.decode(String.self, forKey: .token),
            certificateSHA256: container.decode(Data.self, forKey: .certificateSHA256)
        )
    }
}

enum SamsungPairingCredentialError: Error, Equatable, Sendable {
    case invalidToken
    case invalidCertificateFingerprint
}

/// Brand-scoped identity used as the Keychain account boundary for one Samsung TV.
struct SamsungPairingCredentialIdentity: Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    let reportedDeviceID: String

    init(reportedDeviceID: String) throws {
        let normalized = reportedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.utf8.count <= 512,
            normalized.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw SamsungPairingCredentialIdentityError.invalidReportedDeviceID
        }
        self.reportedDeviceID = normalized
    }

    var stableDeviceKey: String {
        "\(TVBrand.samsung.rawValue):\(reportedDeviceID)"
    }

    var description: String {
        "SamsungPairingCredentialIdentity(redacted)"
    }
}

enum SamsungPairingCredentialIdentityError: LocalizedError, Equatable, Sendable {
    case invalidReportedDeviceID

    var errorDescription: String? {
        "The TV did not provide a usable identity for secure pairing."
    }
}

/// Persistence boundary for TV credentials. Implementations must never use ordinary preferences.
protocol SamsungPairingCredentialStoring: Sendable {
    func credential(
        for identity: SamsungPairingCredentialIdentity,
        migratingLegacyCredentialFor address: PrivateIPv4Address
    ) async throws -> SamsungPairingCredential?
    func save(
        _ credential: SamsungPairingCredential,
        for identity: SamsungPairingCredentialIdentity
    ) async throws
    func removeCredential(
        for identity: SamsungPairingCredentialIdentity,
        legacyAddress: PrivateIPv4Address
    ) async throws
}

/// Stores pairing tokens and certificate pins in this device's data-protection Keychain.
actor KeychainSamsungPairingCredentialStore: SamsungPairingCredentialStoring {
    private let service = "com.shimizutechnology.hafaremote.samsung-pairing"

    func credential(
        for identity: SamsungPairingCredentialIdentity,
        migratingLegacyCredentialFor address: PrivateIPv4Address
    ) throws -> SamsungPairingCredential? {
        if let credential = try readCredential(accountMaterial: identity.stableDeviceKey) {
            return credential
        }
        guard let legacyCredential = try readCredential(accountMaterial: address.rawValue) else {
            return nil
        }

        try save(legacyCredential, for: identity)
        try deleteCredential(accountMaterial: address.rawValue)
        return legacyCredential
    }

    func save(
        _ credential: SamsungPairingCredential,
        for identity: SamsungPairingCredentialIdentity
    ) throws {
        try write(credential, accountMaterial: identity.stableDeviceKey)
    }

    func removeCredential(
        for identity: SamsungPairingCredentialIdentity,
        legacyAddress: PrivateIPv4Address
    ) throws {
        try deleteCredential(accountMaterial: identity.stableDeviceKey)
        try deleteCredential(accountMaterial: legacyAddress.rawValue)
    }

    private func readCredential(accountMaterial: String) throws -> SamsungPairingCredential? {
        var query = baseQuery(accountMaterial: accountMaterial)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SamsungKeychainError.readFailed(status)
        }

        do {
            return try JSONDecoder().decode(SamsungPairingCredential.self, from: data)
        } catch {
            throw SamsungKeychainError.invalidStoredCredential
        }
    }

    private func write(_ credential: SamsungPairingCredential, accountMaterial: String) throws {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(credential)
        } catch {
            throw SamsungKeychainError.encodingFailed
        }

        let query = baseQuery(accountMaterial: accountMaterial)
        let attributes = [kSecValueData as String: encoded]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SamsungKeychainError.writeFailed(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = encoded
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SamsungKeychainError.writeFailed(addStatus)
        }
    }

    private func deleteCredential(accountMaterial: String) throws {
        let status = SecItemDelete(baseQuery(accountMaterial: accountMaterial) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SamsungKeychainError.deleteFailed(status)
        }
    }

    private func baseQuery(accountMaterial: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountIdentifier(for: accountMaterial),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func accountIdentifier(for accountMaterial: String) -> String {
        SHA256.hash(data: Data(accountMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Keychain errors omit address, token, and certificate material by design.
enum SamsungKeychainError: Error, Equatable, Sendable {
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case invalidStoredCredential
}
