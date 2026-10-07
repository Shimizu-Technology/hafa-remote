import Foundation

/// A canonical IPv4 address that is valid only on a private or link-local network.
struct PrivateIPv4Address: Codable, CustomStringConvertible, Equatable, Hashable, Sendable {
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

    #if DEBUG
        /// Constructs RFC 5737 endpoints for injected, non-networking test doubles.
        /// The normal initializer and Codable path continue to reject these addresses.
        init(documentationAddressForTesting candidate: String) throws {
            let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4,
                let first = UInt8(parts[0]), let second = UInt8(parts[1]),
                let third = UInt8(parts[2]), let fourth = UInt8(parts[3]),
                [(192, 0, 2), (198, 51, 100), (203, 0, 113)].contains(where: {
                    $0.0 == Int(first) && $0.1 == Int(second) && $0.2 == Int(third)
                }),
                candidate == [first, second, third, fourth].map(String.init).joined(separator: ".")
            else {
                throw PrivateIPv4AddressError.invalid
            }
            rawValue = candidate
        }
    #endif

    var description: String {
        "PrivateIPv4Address(redacted)"
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
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
