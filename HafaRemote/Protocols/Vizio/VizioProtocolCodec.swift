import Foundation

enum VizioProtocolError: Error, Equatable, Sendable {
    case invalidResponse
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
        guard !token.isEmpty, token.utf8.count <= 512 else {
            throw VizioProtocolError.invalidResponse
        }
        return token
    }

    static func requireSuccess(from data: Data) throws {
        try requireSuccess(decode(VizioStatusOnlyResponse.self, from: data).status)
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
