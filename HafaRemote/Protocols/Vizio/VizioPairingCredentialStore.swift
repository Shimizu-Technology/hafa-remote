import CryptoKit
import Foundation
import Security

protocol VizioPairingCredentialStoring: Sendable {
    func credential(for identity: VizioPairingIdentity) async throws -> VizioPairingCredential?
    func save(_ credential: VizioPairingCredential, for identity: VizioPairingIdentity) async throws
    func remove(for identity: VizioPairingIdentity) async throws
}

protocol VizioPairingCredentialKeychain: Sendable {
    func data(for account: String) throws -> Data?
    func save(_ data: Data, for account: String) throws
    func remove(account: String) throws
}

struct SystemVizioPairingCredentialKeychain: VizioPairingCredentialKeychain {
    private let service = "com.shimizutechnology.hafaremote.vizio.pairing"

    func data(for account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(account: account, returnData: true) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VizioKeychainError.readFailed(status)
        }
        return data
    }

    func save(_ data: Data, for account: String) throws {
        let baseQuery = query(account: account, returnData: false)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw VizioKeychainError.writeFailed(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VizioKeychainError.writeFailed(addStatus)
        }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account: account, returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VizioKeychainError.deleteFailed(status)
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

actor KeychainVizioPairingCredentialStore: VizioPairingCredentialStoring {
    private let keychain: any VizioPairingCredentialKeychain

    init(keychain: any VizioPairingCredentialKeychain = SystemVizioPairingCredentialKeychain()) {
        self.keychain = keychain
    }

    func credential(for identity: VizioPairingIdentity) throws -> VizioPairingCredential? {
        let account = account(for: identity)
        guard let data = try keychain.data(for: account) else { return nil }
        guard let credential = try? JSONDecoder().decode(VizioPairingCredential.self, from: data) else {
            try keychain.remove(account: account)
            throw VizioKeychainError.invalidStoredCredential
        }
        return credential
    }

    func save(_ credential: VizioPairingCredential, for identity: VizioPairingIdentity) throws {
        guard let data = try? JSONEncoder().encode(credential) else {
            throw VizioKeychainError.encodingFailed
        }
        try keychain.save(data, for: account(for: identity))
    }

    func remove(for identity: VizioPairingIdentity) throws {
        try keychain.remove(account: account(for: identity))
    }

    private func account(for identity: VizioPairingIdentity) -> String {
        SHA256.hash(data: Data(identity.stableDeviceKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum VizioKeychainError: Error, Equatable, Sendable {
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case invalidStoredCredential
}
