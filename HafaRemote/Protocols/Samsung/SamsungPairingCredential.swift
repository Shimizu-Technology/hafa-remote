import CryptoKit
import Foundation
import Security

/// The minimum credential needed to reconnect to one approved television safely.
struct SamsungPairingCredential: Codable, Equatable, Sendable {
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

/// Persistence boundary for TV credentials. Implementations must never use ordinary preferences.
protocol SamsungPairingCredentialStoring: Sendable {
    func credential(for address: PrivateIPv4Address) async throws -> SamsungPairingCredential?
    func save(_ credential: SamsungPairingCredential, for address: PrivateIPv4Address) async throws
    func removeCredential(for address: PrivateIPv4Address) async throws
}

/// Stores pairing tokens and certificate pins in this device's data-protection Keychain.
actor KeychainSamsungPairingCredentialStore: SamsungPairingCredentialStoring {
    private let service = "com.shimizutechnology.hafaremote.samsung-pairing"

    func credential(for address: PrivateIPv4Address) throws -> SamsungPairingCredential? {
        var query = baseQuery(for: address)
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

    func save(_ credential: SamsungPairingCredential, for address: PrivateIPv4Address) throws {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(credential)
        } catch {
            throw SamsungKeychainError.encodingFailed
        }

        let query = baseQuery(for: address)
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

    func removeCredential(for address: PrivateIPv4Address) throws {
        let status = SecItemDelete(baseQuery(for: address) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SamsungKeychainError.deleteFailed(status)
        }
    }

    private func baseQuery(for address: PrivateIPv4Address) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountIdentifier(for: address),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func accountIdentifier(for address: PrivateIPv4Address) -> String {
        SHA256.hash(data: Data(address.rawValue.utf8))
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
