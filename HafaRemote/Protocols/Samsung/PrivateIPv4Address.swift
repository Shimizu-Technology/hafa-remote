import Foundation

/// A canonical IPv4 address that is valid only on a private or link-local network.
struct PrivateIPv4Address: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ candidate: String) throws {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            throw PrivateIPv4AddressError.invalid
        }

        let octets = try parts.map { part -> UInt8 in
            guard !part.isEmpty,
                part.allSatisfy(\.isNumber),
                part.count == 1 || part.first != "0",
                let value = UInt8(part)
            else {
                throw PrivateIPv4AddressError.invalid
            }
            return value
        }

        guard Self.isPrivate(octets) else {
            throw PrivateIPv4AddressError.notPrivate
        }

        rawValue = octets.map(String.init).joined(separator: ".")
    }

    private static func isPrivate(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254):
            true
        case (172, 16...31):
            true
        default:
            false
        }
    }
}

/// Validation failures that are safe to show without repeating the entered address.
enum PrivateIPv4AddressError: LocalizedError, Equatable, Sendable {
    case invalid
    case notPrivate

    var errorDescription: String? {
        switch self {
        case .invalid:
            "Enter a valid IPv4 address, such as 192.168.1.25."
        case .notPrivate:
            "Use a private address from your home Wi-Fi network."
        }
    }
}
