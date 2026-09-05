import CryptoKit
import Foundation
import Security

enum SonyClientIdentityError: Error, Equatable, Sendable {
    case keyGenerationFailed
    case certificateGenerationFailed
    case certificateStorageFailed(OSStatus)
    case identityLookupFailed(OSStatus)
    case invalidPublicKey
    case invalidPairingCode
    case pairingCodeMismatch
}

struct SonyRSAKeyComponents: Equatable, Sendable {
    let modulus: Data
    let exponent: Data

    init(publicKey: SecKey) throws {
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SonyClientIdentityError.invalidPublicKey
        }
        var reader = SonyDERReader(data: representation)
        let sequence = try reader.read(tag: 0x30)
        guard reader.isAtEnd else { throw SonyClientIdentityError.invalidPublicKey }
        var components = SonyDERReader(data: sequence)
        modulus = try Self.unsignedInteger(components.read(tag: 0x02))
        exponent = try Self.unsignedInteger(components.read(tag: 0x02))
        guard components.isAtEnd, !modulus.isEmpty, !exponent.isEmpty else {
            throw SonyClientIdentityError.invalidPublicKey
        }
    }

    init(certificate: SecCertificate) throws {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            throw SonyClientIdentityError.invalidPublicKey
        }
        try self.init(publicKey: publicKey)
    }

    private static func unsignedInteger(_ encoded: Data) throws -> Data {
        var bytes = Array(encoded)
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        guard !bytes.isEmpty else { throw SonyClientIdentityError.invalidPublicKey }
        return Data(bytes)
    }
}

enum SonyPairingSecret {
    static func make(
        pairingCode: String,
        clientCertificate: SecCertificate,
        serverCertificate: SecCertificate
    ) throws -> Data {
        let normalized = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.utf8.count == 6,
            normalized.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789ABCDEF").contains($0)
            }),
            let expectedPrefix = UInt8(normalized.prefix(2), radix: 16),
            let suffix = Data(hexadecimal: String(normalized.dropFirst(2)))
        else {
            throw SonyClientIdentityError.invalidPairingCode
        }

        let digest = try digest(
            suffix: suffix,
            clientCertificate: clientCertificate,
            serverCertificate: serverCertificate
        )
        guard digest.first == expectedPrefix else {
            throw SonyClientIdentityError.pairingCodeMismatch
        }
        return digest
    }

    static func displayCode(
        suffix: Data,
        clientCertificate: SecCertificate,
        serverCertificate: SecCertificate
    ) throws -> String {
        guard suffix.count == 2 else { throw SonyClientIdentityError.invalidPairingCode }
        let digest = try digest(
            suffix: suffix,
            clientCertificate: clientCertificate,
            serverCertificate: serverCertificate
        )
        guard let prefix = digest.first else { throw SonyClientIdentityError.invalidPairingCode }
        return String(format: "%02X", prefix) + suffix.map { String(format: "%02X", $0) }.joined()
    }

    private static func digest(
        suffix: Data,
        clientCertificate: SecCertificate,
        serverCertificate: SecCertificate
    ) throws -> Data {
        let client = try SonyRSAKeyComponents(certificate: clientCertificate)
        let server = try SonyRSAKeyComponents(certificate: serverCertificate)
        var material = Data()
        material.append(client.modulus)
        material.append(client.exponent)
        material.append(server.modulus)
        material.append(server.exponent)
        material.append(suffix)
        return Data(SHA256.hash(data: material))
    }
}

final class SonyClientIdentityStore: @unchecked Sendable {
    private let keyTag: Data
    private let certificateLabel: String
    private let lock = NSLock()

    init(namespace: String = "com.shimizutechnology.hafaremote.sony-client") {
        keyTag = Data("\(namespace).key".utf8)
        certificateLabel = "\(namespace).certificate"
    }

    func identity() throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }

        if let certificate = try savedCertificate() {
            return try identity(for: certificate)
        }

        let privateKey = try createPrivateKey()
        let serial = try secureRandomBytes(count: 16)
        let certificate = try SonyClientCertificateFactory.make(
            privateKey: privateKey,
            commonName: "Hafa Remote",
            serialNumber: serial
        )
        try save(certificate: certificate)
        return try identity(for: certificate)
    }

    private func savedCertificate() throws -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certificateLabel,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
            let data = result as? Data,
            let certificate = SecCertificateCreateWithData(nil, data as CFData)
        else {
            throw SonyClientIdentityError.identityLookupFailed(status)
        }
        return certificate
    }

    private func createPrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SonyClientIdentityError.keyGenerationFailed
        }
        return key
    }

    private func save(certificate: SecCertificate) throws {
        let status = SecItemAdd(
            [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrLabel as String: certificateLabel,
            ] as CFDictionary,
            nil
        )
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw SonyClientIdentityError.certificateStorageFailed(status)
        }
    }

    private func identity(for certificate: SecCertificate) throws -> SecIdentity {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassIdentity,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ] as CFDictionary,
            &result
        )
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw SonyClientIdentityError.identityLookupFailed(status)
        }
        let expectedData = SecCertificateCopyData(certificate)
        for identity in identities {
            var storedCertificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &storedCertificate) == errSecSuccess,
                let storedCertificate
            else {
                continue
            }
            if SecCertificateCopyData(storedCertificate) == expectedData {
                return identity
            }
        }
        throw SonyClientIdentityError.identityLookupFailed(errSecItemNotFound)
    }

    private func secureRandomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw SonyClientIdentityError.keyGenerationFailed
        }
        return Data(bytes)
    }
}

enum SonyClientCertificateFactory {
    static func make(
        privateKey: SecKey,
        commonName: String,
        serialNumber: Data,
        now: Date = .now
    ) throws -> SecCertificate {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SonyClientIdentityError.certificateGenerationFailed
        }
        var keyError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &keyError) as Data? else {
            throw SonyClientIdentityError.certificateGenerationFailed
        }

        let signatureAlgorithm = SonyDER.sequence(
            SonyDER.objectIdentifier([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
                + SonyDER.null
        )
        let rsaAlgorithm = SonyDER.sequence(
            SonyDER.objectIdentifier([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
                + SonyDER.null
        )
        let name = SonyDER.sequence(
            SonyDER.set(
                SonyDER.sequence(
                    SonyDER.objectIdentifier([0x55, 0x04, 0x03])
                        + SonyDER.utf8String(String(commonName.prefix(64)))
                )
            )
        )
        let notBefore = now.addingTimeInterval(-86_400)
        let notAfter = now.addingTimeInterval(86_400 * 365 * 10)
        let subjectPublicKeyInfo = SonyDER.sequence(
            rsaAlgorithm + SonyDER.bitString(publicKeyData)
        )
        let tbsCertificate = SonyDER.sequence(
            SonyDER.explicit(tag: 0, SonyDER.integer(Data([2])))
                + SonyDER.integer(serialNumber)
                + signatureAlgorithm
                + name
                + SonyDER.sequence(SonyDER.utcTime(notBefore) + SonyDER.utcTime(notAfter))
                + name
                + subjectPublicKeyInfo
        )

        var signingError: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                privateKey,
                .rsaSignatureMessagePKCS1v15SHA256,
                tbsCertificate as CFData,
                &signingError
            ) as Data?
        else {
            throw SonyClientIdentityError.certificateGenerationFailed
        }
        let certificateData = SonyDER.sequence(
            tbsCertificate + signatureAlgorithm + SonyDER.bitString(signature)
        )
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw SonyClientIdentityError.certificateGenerationFailed
        }
        return certificate
    }
}

private enum SonyDER {
    static let null = Data([0x05, 0x00])

    static func sequence(_ content: Data) -> Data { tagged(0x30, content) }
    static func set(_ content: Data) -> Data { tagged(0x31, content) }
    static func objectIdentifier(_ bytes: [UInt8]) -> Data { tagged(0x06, Data(bytes)) }
    static func utf8String(_ value: String) -> Data { tagged(0x0C, Data(value.utf8)) }
    static func explicit(tag: UInt8, _ content: Data) -> Data { tagged(0xA0 | tag, content) }

    static func integer(_ value: Data) -> Data {
        var bytes = Array(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(0x02, Data(bytes))
    }

    static func bitString(_ value: Data) -> Data {
        tagged(0x03, Data([0]) + value)
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: date).utf8))
    }

    private static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

private struct SonyDERReader {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool { index == bytes.count }

    mutating func read(tag expectedTag: UInt8) throws -> Data {
        guard index < bytes.count, bytes[index] == expectedTag else {
            throw SonyClientIdentityError.invalidPublicKey
        }
        index += 1
        let length = try readLength()
        guard length >= 0, index <= bytes.count - length else {
            throw SonyClientIdentityError.invalidPublicKey
        }
        let value = Data(bytes[index..<(index + length)])
        index += length
        return value
    }

    private mutating func readLength() throws -> Int {
        guard index < bytes.count else { throw SonyClientIdentityError.invalidPublicKey }
        let first = bytes[index]
        index += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= MemoryLayout<Int>.size, index <= bytes.count - count else {
            throw SonyClientIdentityError.invalidPublicKey
        }
        var length = 0
        for _ in 0..<count {
            guard length <= (Int.max >> 8) else {
                throw SonyClientIdentityError.invalidPublicKey
            }
            length = (length << 8) | Int(bytes[index])
            index += 1
        }
        return length
    }
}

extension Data {
    fileprivate init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
