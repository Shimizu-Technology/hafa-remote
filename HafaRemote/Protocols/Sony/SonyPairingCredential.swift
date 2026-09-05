import Foundation
import Security

struct SonyPairingCredential: Codable, Equatable, Sendable {
    static let fingerprintByteCount = 32

    let certificateSHA256: Data

    init(certificateSHA256: Data) throws {
        guard certificateSHA256.count == Self.fingerprintByteCount else {
            throw SonyPairingCredentialError.invalidFingerprint
        }
        self.certificateSHA256 = certificateSHA256
    }

    var reportedDeviceID: String {
        certificateSHA256.map { String(format: "%02x", $0) }.joined()
    }

    init(reportedDeviceID: String) throws {
        guard reportedDeviceID.count == Self.fingerprintByteCount * 2 else {
            throw SonyPairingCredentialError.invalidFingerprint
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.fingerprintByteCount)
        var index = reportedDeviceID.startIndex
        while index < reportedDeviceID.endIndex {
            let next = reportedDeviceID.index(index, offsetBy: 2)
            guard let byte = UInt8(reportedDeviceID[index..<next], radix: 16) else {
                throw SonyPairingCredentialError.invalidFingerprint
            }
            bytes.append(byte)
            index = next
        }
        try self.init(certificateSHA256: Data(bytes))
    }
}

enum SonyPairingCredentialError: Error, Equatable, Sendable {
    case invalidFingerprint
}

protocol SonyPairingCredentialStoring: Sendable {
    func credential(for certificateSHA256: Data) async throws -> SonyPairingCredential?
    func save(_ credential: SonyPairingCredential) async throws
    func remove(reportedDeviceID: String) async throws
}

enum SonyRecoverableCredentialLookup {
    static func credential(
        in store: any SonyPairingCredentialStoring,
        fingerprint: Data
    ) async throws -> SonyPairingCredential? {
        do {
            return try await store.credential(for: fingerprint)
        } catch SonyKeychainError.invalidStoredCredential {
            // The store has already deleted the malformed entry. Treat it as absent
            // so the physical-TV approval flow can issue a replacement credential.
            return nil
        }
    }
}

protocol SonyPairingCredentialKeychain: Sendable {
    func data(for account: String) throws -> Data?
    func save(_ data: Data, for account: String) throws
    func remove(account: String) throws
}

struct SystemSonyPairingCredentialKeychain: SonyPairingCredentialKeychain {
    private let service = "com.shimizutechnology.hafaremote.sony.pairing"

    func data(for account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query(account: account, returnData: true) as CFDictionary,
            &result
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SonyKeychainError.readFailed(status)
        }
        return data
    }

    func save(_ data: Data, for account: String) throws {
        let baseQuery = query(account: account, returnData: false)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SonyKeychainError.writeFailed(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SonyKeychainError.writeFailed(addStatus)
        }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account: account, returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SonyKeychainError.deleteFailed(status)
        }
    }

    private func query(account: String, returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}

actor KeychainSonyPairingCredentialStore: SonyPairingCredentialStoring {
    private let keychain: any SonyPairingCredentialKeychain

    init(keychain: any SonyPairingCredentialKeychain = SystemSonyPairingCredentialKeychain()) {
        self.keychain = keychain
    }

    func credential(for certificateSHA256: Data) throws -> SonyPairingCredential? {
        let candidate = try SonyPairingCredential(certificateSHA256: certificateSHA256)
        guard let data = try keychain.data(for: candidate.reportedDeviceID) else { return nil }
        guard let credential = try? JSONDecoder().decode(SonyPairingCredential.self, from: data),
            credential == candidate
        else {
            try? keychain.remove(account: candidate.reportedDeviceID)
            throw SonyKeychainError.invalidStoredCredential
        }
        return credential
    }

    func save(_ credential: SonyPairingCredential) throws {
        guard let data = try? JSONEncoder().encode(credential) else {
            throw SonyKeychainError.encodingFailed
        }
        try keychain.save(data, for: credential.reportedDeviceID)
    }

    func remove(reportedDeviceID: String) throws {
        let credential = try SonyPairingCredential(reportedDeviceID: reportedDeviceID)
        try keychain.remove(account: credential.reportedDeviceID)
    }
}

enum SonyKeychainError: Error, Equatable, Sendable {
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case invalidStoredCredential
}
