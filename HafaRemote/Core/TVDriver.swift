import Foundation

enum TVBrand: String, Codable, CaseIterable, Hashable, Sendable {
    case samsung
    case sony
    case vizio

    var displayName: String {
        switch self {
        case .samsung:
            "Samsung"
        case .sony:
            "Sony"
        case .vizio:
            "Vizio"
        }
    }

    var defaultDeviceName: String {
        "\(displayName) TV"
    }
}

enum TVNetworkConnection: Equatable, Sendable {
    case unavailable
    case wireless
    case wired
}

/// A discovery result reduced to the fields a brand driver needs to start a session.
struct TVConnectionTarget: Equatable, Sendable {
    let brand: TVBrand
    let reportedDeviceID: String
    let address: PrivateIPv4Address
    let controlPort: UInt16?
}

/// A validated hardware address that is never rendered or logged verbatim.
struct TVMACAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    let octets: [UInt8]

    init(_ value: String) throws {
        let compact = value.filter { $0 != ":" && $0 != "-" }
        guard compact.count == 12, compact.allSatisfy(\.isHexDigit) else {
            throw TVMACAddressError.invalid
        }

        var parsed: [UInt8] = []
        parsed.reserveCapacity(6)
        var index = compact.startIndex
        for _ in 0..<6 {
            let next = compact.index(index, offsetBy: 2)
            guard let octet = UInt8(compact[index..<next], radix: 16) else {
                throw TVMACAddressError.invalid
            }
            parsed.append(octet)
            index = next
        }

        guard
            parsed.contains(where: { $0 != 0 }),
            parsed.contains(where: { $0 != 0xFF }),
            parsed[0] & 1 == 0
        else {
            throw TVMACAddressError.invalid
        }
        octets = parsed
    }

    var persistedValue: String {
        octets.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    var description: String {
        "TVMACAddress(redacted)"
    }
}

enum TVMACAddressError: LocalizedError, Equatable, Sendable {
    case invalid

    var errorDescription: String? {
        "The TV did not provide a usable network address for power on."
    }
}

/// Brand-neutral information confirmed by a successful control connection.
struct ConnectedTV: Equatable, Sendable {
    let brand: TVBrand
    let reportedDeviceID: String
    let address: PrivateIPv4Address
    let controlPort: UInt16?
    let modelName: String
    let firmwareVersion: String?
    let networkConnection: TVNetworkConnection
    let macAddress: TVMACAddress?

    init(
        brand: TVBrand = .samsung,
        reportedDeviceID: String,
        address: PrivateIPv4Address,
        controlPort: UInt16? = nil,
        modelName: String,
        firmwareVersion: String?,
        networkConnection: TVNetworkConnection = .unavailable,
        macAddress: TVMACAddress? = nil
    ) {
        self.brand = brand
        self.reportedDeviceID = reportedDeviceID
        self.address = address
        self.controlPort = controlPort
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.networkConnection = networkConnection
        self.macAddress = macAddress
    }

    var stableDeviceKey: String {
        "\(brand.rawValue):\(reportedDeviceID)"
    }

    var isEligibleForSamsungWake: Bool {
        brand == .samsung && networkConnection == .wireless
    }
}

typealias SamsungNetworkConnection = TVNetworkConnection
typealias SamsungMACAddress = TVMACAddress
typealias SamsungMACAddressError = TVMACAddressError
typealias PairedSamsungTV = ConnectedTV

/// The command boundary between product features and a television-specific protocol.
protocol TVDriver: Sendable {
    /// Sends one semantic remote action to the active television connection.
    func send(_ command: RemoteCommand) async throws

    /// Sends text to the text field currently focused on the television.
    func sendText(_ input: RemoteTextInput) async throws

    /// Ends the active connection and releases its network resources.
    func disconnect() async
}

extension TVDriver {
    func sendText(_ input: RemoteTextInput) async throws {
        throw TVDriverError.unsupportedTextInput
    }
}

/// Validated text that may cross the television protocol boundary.
struct RemoteTextInput: Equatable, Sendable, CustomStringConvertible {
    static let maximumCharacterCount = 256

    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty,
            value.count <= Self.maximumCharacterCount,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw RemoteTextInputError.invalidText
        }
        self.value = value
    }

    var description: String {
        "RemoteTextInput(redacted, characters: \(value.count))"
    }
}

enum RemoteTextInputError: LocalizedError, Equatable, Sendable {
    case invalidText

    var errorDescription: String? {
        "Enter between 1 and \(RemoteTextInput.maximumCharacterCount) characters without control characters."
    }
}

enum TVDriverError: LocalizedError, Equatable, Sendable {
    case unsupportedTextInput

    var errorDescription: String? {
        "This TV connection does not support remote text input."
    }
}
