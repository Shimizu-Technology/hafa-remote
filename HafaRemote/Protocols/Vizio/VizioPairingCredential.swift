import Foundation

struct VizioPairingCredential: Codable, CustomStringConvertible, Equatable, Sendable {
    let authToken: String
    let certificateSHA256: Data
    let clientID: String

    init(authToken: String, certificateSHA256: Data, clientID: String) throws {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
            token.utf8.count <= 512,
            token.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw VizioPairingCredentialError.invalidAuthToken
        }
        guard certificateSHA256.count == 32 else {
            throw VizioPairingCredentialError.invalidCertificateFingerprint
        }
        guard UUID(uuidString: identifier) != nil else {
            throw VizioPairingCredentialError.invalidClientID
        }
        self.authToken = token
        self.certificateSHA256 = certificateSHA256
        self.clientID = identifier.lowercased()
    }

    var description: String {
        "VizioPairingCredential(redacted)"
    }

    private enum CodingKeys: String, CodingKey {
        case authToken
        case certificateSHA256
        case clientID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            authToken: container.decode(String.self, forKey: .authToken),
            certificateSHA256: container.decode(Data.self, forKey: .certificateSHA256),
            clientID: container.decode(String.self, forKey: .clientID)
        )
    }
}

enum VizioPairingCredentialError: Error, Equatable, Sendable {
    case invalidAuthToken
    case invalidCertificateFingerprint
    case invalidClientID
    case invalidReportedDeviceID
}

struct VizioPairingIdentity: Equatable, Hashable, Sendable, CustomStringConvertible {
    let reportedDeviceID: String

    init(reportedDeviceID: String) throws {
        let normalized = reportedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.utf8.count <= 512,
            normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw VizioPairingCredentialError.invalidReportedDeviceID
        }
        self.reportedDeviceID = normalized
    }

    var stableDeviceKey: String {
        "\(TVBrand.vizio.rawValue):\(reportedDeviceID)"
    }

    var description: String {
        "VizioPairingIdentity(redacted)"
    }
}
