import Foundation

enum VizioProtocolError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidPairingTransition
    case rejected(String)
    case unsupportedCommand
}

struct VizioPairingChallenge: Equatable, Sendable {
    let challengeType: Int
    let requestToken: Int
}

struct VizioRemoteKey: Equatable, Sendable {
    let codeSet: Int
    let code: Int
}

struct VizioDeviceInfo: Equatable, Sendable {
    let reportedDeviceID: String
    let displayName: String
    let modelName: String
    let firmwareVersion: String?
}

enum VizioPairingState: Equatable, Sendable {
    case idle
    case awaitingPIN(VizioPairingChallenge)
    case paired
    case cancelled
    case failed
}

enum VizioPairingEvent: Equatable, Sendable {
    case receivedChallenge(VizioPairingChallenge)
    case acceptedPIN
    case cancelled
    case failed
}

struct VizioPairingStateMachine: Sendable {
    private(set) var state: VizioPairingState = .idle

    mutating func apply(_ event: VizioPairingEvent) throws {
        switch (state, event) {
        case (.idle, .receivedChallenge(let challenge)):
            state = .awaitingPIN(challenge)
        case (.awaitingPIN, .acceptedPIN):
            state = .paired
        case (.idle, .cancelled), (.awaitingPIN, .cancelled):
            state = .cancelled
        case (.idle, .failed), (.awaitingPIN, .failed):
            state = .failed
        default:
            throw VizioProtocolError.invalidPairingTransition
        }
    }
}

enum VizioProtocolCodec {
    static func beginPairing(deviceID: String, deviceName: String = "Hafa Remote") throws -> Data {
        try encode(
            VizioBeginPairingRequest(
                deviceID: deviceID,
                deviceName: String(deviceName.prefix(80))
            )
        )
    }

    static func finishPairing(
        deviceID: String,
        challenge: VizioPairingChallenge,
        pin: String
    ) throws -> Data {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else {
            throw VizioProtocolError.invalidResponse
        }
        return try encode(
            VizioFinishPairingRequest(
                deviceID: deviceID,
                challengeType: challenge.challengeType,
                requestToken: challenge.requestToken,
                responseValue: pin
            )
        )
    }

    static func cancelPairing(deviceID: String, deviceName: String = "Hafa Remote") throws -> Data {
        try beginPairing(deviceID: deviceID, deviceName: deviceName)
    }

    static func remoteCommand(_ command: RemoteCommand) throws -> Data {
        let key: VizioRemoteKey
        switch command {
        case .powerOn:
            key = VizioRemoteKey(codeSet: 11, code: 1)
        case .powerOff:
            key = VizioRemoteKey(codeSet: 11, code: 0)
        case .up:
            key = VizioRemoteKey(codeSet: 3, code: 8)
        case .down:
            key = VizioRemoteKey(codeSet: 3, code: 0)
        case .left:
            key = VizioRemoteKey(codeSet: 3, code: 1)
        case .right:
            key = VizioRemoteKey(codeSet: 3, code: 7)
        case .select:
            key = VizioRemoteKey(codeSet: 3, code: 2)
        case .home:
            key = VizioRemoteKey(codeSet: 4, code: 15)
        case .back:
            key = VizioRemoteKey(codeSet: 4, code: 0)
        case .play:
            key = VizioRemoteKey(codeSet: 2, code: 3)
        case .pause:
            key = VizioRemoteKey(codeSet: 2, code: 2)
        case .rewind:
            key = VizioRemoteKey(codeSet: 2, code: 1)
        case .fastForward:
            key = VizioRemoteKey(codeSet: 2, code: 0)
        case .volumeUp:
            key = VizioRemoteKey(codeSet: 5, code: 1)
        case .volumeDown:
            key = VizioRemoteKey(codeSet: 5, code: 0)
        case .mute:
            key = VizioRemoteKey(codeSet: 5, code: 4)
        }
        return try encode(
            VizioKeyCommandRequest(
                keys: [
                    VizioKeyCommand(
                        codeSet: key.codeSet,
                        code: key.code,
                        action: "KEYPRESS"
                    )
                ]
            )
        )
    }

    static func pairingChallenge(from data: Data) throws -> VizioPairingChallenge {
        let response = try decode(VizioPairingChallengeResponse.self, from: data)
        try requireSuccess(response.status)
        return VizioPairingChallenge(
            challengeType: response.item.challengeType,
            requestToken: response.item.requestToken
        )
    }

    static func authToken(from data: Data) throws -> String {
        let response = try decode(VizioPairingTokenResponse.self, from: data)
        try requireSuccess(response.status)
        let token = response.item.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
            token.utf8.count <= 512,
            token.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw VizioProtocolError.invalidResponse
        }
        return token
    }

    static func requireSuccess(from data: Data) throws {
        try requireSuccess(decode(VizioStatusOnlyResponse.self, from: data).status)
    }

    static func deviceInfo(from data: Data) throws -> VizioDeviceInfo {
        let response = try decode(VizioDeviceInfoResponse.self, from: data)
        try requireSuccess(response.status)
        guard let item = response.preferredItem else {
            throw VizioProtocolError.invalidResponse
        }
        let reportedDeviceID = try validatedText(item.serialNumber, maximumBytes: 512)
        let displayName = try validatedText(item.castName, maximumBytes: 80)
        let modelName = try validatedText(item.modelName, maximumBytes: 80)
        let firmware = item.firmwareVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let firmware,
            firmware.utf8.count > 80
                || firmware.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        {
            throw VizioProtocolError.invalidResponse
        }
        return VizioDeviceInfo(
            reportedDeviceID: reportedDeviceID,
            displayName: displayName,
            modelName: modelName,
            firmwareVersion: firmware.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func requireSuccess(_ status: VizioStatus) throws {
        guard status.result.caseInsensitiveCompare("SUCCESS") == .orderedSame else {
            throw VizioProtocolError.rejected(String(status.result.prefix(80)))
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw VizioProtocolError.invalidResponse
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw VizioProtocolError.invalidResponse
        }
    }

    private static func validatedText(_ value: String, maximumBytes: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.utf8.count <= maximumBytes,
            !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw VizioProtocolError.invalidResponse
        }
        return normalized
    }
}

private struct VizioBeginPairingRequest: Encodable {
    let deviceID: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "DEVICE_ID"
        case deviceName = "DEVICE_NAME"
    }
}

private struct VizioFinishPairingRequest: Encodable {
    let deviceID: String
    let challengeType: Int
    let requestToken: Int
    let responseValue: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "DEVICE_ID"
        case challengeType = "CHALLENGE_TYPE"
        case requestToken = "PAIRING_REQ_TOKEN"
        case responseValue = "RESPONSE_VALUE"
    }
}

private struct VizioKeyCommandRequest: Encodable {
    let keys: [VizioKeyCommand]

    enum CodingKeys: String, CodingKey {
        case keys = "KEYLIST"
    }
}

private struct VizioKeyCommand: Encodable {
    let codeSet: Int
    let code: Int
    let action: String

    enum CodingKeys: String, CodingKey {
        case codeSet = "CODESET"
        case code = "CODE"
        case action = "ACTION"
    }
}

private struct VizioStatus: Decodable {
    let result: String

    enum CodingKeys: String, CodingKey {
        case result = "RESULT"
    }
}

private struct VizioStatusOnlyResponse: Decodable {
    let status: VizioStatus

    enum CodingKeys: String, CodingKey {
        case status = "STATUS"
    }
}

private struct VizioPairingChallengeResponse: Decodable {
    let status: VizioStatus
    let item: Item

    struct Item: Decodable {
        let challengeType: Int
        let requestToken: Int

        enum CodingKeys: String, CodingKey {
            case challengeType = "CHALLENGE_TYPE"
            case requestToken = "PAIRING_REQ_TOKEN"
        }
    }

    enum CodingKeys: String, CodingKey {
        case status = "STATUS"
        case item = "ITEM"
    }
}

private struct VizioPairingTokenResponse: Decodable {
    let status: VizioStatus
    let item: Item

    struct Item: Decodable {
        let authToken: String

        enum CodingKeys: String, CodingKey {
            case authToken = "AUTH_TOKEN"
        }
    }

    enum CodingKeys: String, CodingKey {
        case status = "STATUS"
        case item = "ITEM"
    }
}

private struct VizioDeviceInfoResponse: Decodable {
    let status: VizioStatus
    let item: Item?
    let items: [Item]

    struct Item: Decodable {
        let value: Value?
        let serialNumber: String?
        let castName: String?
        let modelName: String?
        let firmwareVersion: String?

        var normalizedValue: Value? {
            if let value { return value }
            guard serialNumber != nil || castName != nil || modelName != nil else { return nil }
            return Value(
                serialNumber: serialNumber,
                castName: castName,
                modelName: modelName,
                firmwareVersion: firmwareVersion,
                systemInfo: nil
            )
        }

        enum CodingKeys: String, CodingKey {
            case value = "VALUE"
            case serialNumber = "SERIAL_NUMBER"
            case castName = "CAST_NAME"
            case modelName = "MODEL_NAME"
            case firmwareVersion = "VERSION"
        }
    }

    struct Value: Decodable {
        let serialNumber: String?
        let castName: String?
        let modelName: String?
        let firmwareVersion: String?
        let systemInfo: SystemInfo?

        var resolvedSerialNumber: String? { systemInfo?.serialNumber ?? serialNumber }
        var resolvedModelName: String? { modelName ?? systemInfo?.modelName }
        var resolvedFirmwareVersion: String? { systemInfo?.firmwareVersion ?? firmwareVersion }

        enum CodingKeys: String, CodingKey {
            case serialNumber = "SERIAL_NUMBER"
            case castName = "CAST_NAME"
            case modelName = "MODEL_NAME"
            case firmwareVersion = "VERSION"
            case systemInfo = "SYSTEM_INFO"
        }
    }

    struct SystemInfo: Decodable {
        let serialNumber: String?
        let modelName: String?
        let firmwareVersion: String?

        enum CodingKeys: String, CodingKey {
            case serialNumber = "SERIAL_NUMBER"
            case modelName = "MODEL_NAME"
            case firmwareVersion = "VERSION"
        }
    }

    struct NormalizedItem {
        let serialNumber: String
        let castName: String
        let modelName: String
        let firmwareVersion: String?
    }

    var preferredItem: NormalizedItem? {
        let values = items.compactMap(\.normalizedValue) + [item?.normalizedValue].compactMap { $0 }
        guard
            let value = values.first(where: {
                $0.resolvedSerialNumber != nil && $0.castName != nil && $0.resolvedModelName != nil
            }),
            let serialNumber = value.resolvedSerialNumber,
            let castName = value.castName,
            let modelName = value.resolvedModelName
        else {
            return nil
        }
        return NormalizedItem(
            serialNumber: serialNumber,
            castName: castName,
            modelName: modelName,
            firmwareVersion: value.resolvedFirmwareVersion
        )
    }

    enum CodingKeys: String, CodingKey {
        case status = "STATUS"
        case item = "ITEM"
        case items = "ITEMS"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(VizioStatus.self, forKey: .status)
        item = try container.decodeIfPresent(Item.self, forKey: .item)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
    }
}
