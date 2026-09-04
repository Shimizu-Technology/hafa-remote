import Foundation

/// Encodes the reviewed Samsung command allowlist and decodes pairing events.
enum SamsungProtocolCodec {
    static func remoteMessage(for command: RemoteCommand) throws -> URLSessionWebSocketTask.Message {
        let key: String
        switch command {
        case .powerOff:
            // Newer Tizen TVs use KEY_POWER for power-off while the secure
            // session proves the television is currently awake.
            key = "KEY_POWER"
        case .up:
            key = "KEY_UP"
        case .down:
            key = "KEY_DOWN"
        case .left:
            key = "KEY_LEFT"
        case .right:
            key = "KEY_RIGHT"
        case .select:
            key = "KEY_ENTER"
        case .home:
            key = "KEY_HOME"
        case .back:
            key = "KEY_RETURN"
        case .play:
            key = "KEY_PLAY"
        case .pause:
            key = "KEY_PAUSE"
        case .rewind:
            key = "KEY_REWIND"
        case .fastForward:
            key = "KEY_FF"
        case .volumeUp:
            key = "KEY_VOLUP"
        case .volumeDown:
            key = "KEY_VOLDOWN"
        case .mute:
            key = "KEY_MUTE"
        }

        let request = SamsungRemoteControlRequest(
            method: "ms.remote.control",
            params: .init(
                command: "Click",
                data: key,
                option: "false",
                remoteType: "SendRemoteKey"
            )
        )
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SamsungProtocolError.invalidCommandEncoding
        }
        return .string(text)
    }

    static func event(from message: URLSessionWebSocketTask.Message) throws -> SamsungConnectionEvent {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            guard let value = value.data(using: .utf8) else {
                throw SamsungProtocolError.invalidEvent
            }
            data = value
        @unknown default:
            throw SamsungProtocolError.invalidEvent
        }

        let envelope: SamsungEventEnvelope
        do {
            envelope = try JSONDecoder().decode(SamsungEventEnvelope.self, from: data)
        } catch {
            throw SamsungProtocolError.invalidEvent
        }

        switch envelope.event {
        case "ms.channel.connect":
            return .connected(token: envelope.token)
        case "ms.channel.unauthorized":
            return .unauthorized
        default:
            return .ignored
        }
    }
}

enum SamsungConnectionEvent: Equatable, Sendable {
    case connected(token: String?)
    case unauthorized
    case ignored
}

enum SamsungProtocolError: Error, Equatable, Sendable {
    case invalidCommandEncoding
    case invalidEvent
}

private struct SamsungRemoteControlRequest: Encodable {
    let method: String
    let params: Parameters

    struct Parameters: Encodable {
        let command: String
        let data: String
        let option: String
        let remoteType: String

        enum CodingKeys: String, CodingKey {
            case command = "Cmd"
            case data = "DataOfCmd"
            case option = "Option"
            case remoteType = "TypeOfRemote"
        }
    }
}

private struct SamsungEventEnvelope: Decodable {
    let event: String
    let token: String?

    private enum CodingKeys: String, CodingKey {
        case event
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(String.self, forKey: .event)
        token = try? container.decode(Payload.self, forKey: .data).token
    }

    private struct Payload: Decodable {
        let token: String?
    }
}

/// Builds the private WebSocket endpoint without exposing it through logs or diagnostics.
enum SamsungWebSocketURLBuilder {
    static func url(
        address: PrivateIPv4Address,
        token: String?
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = address.rawValue
        components.port = 8002
        components.path = "/api/v2/channels/samsung.remote.control"

        let encodedName = Data("Hafa Remote".utf8).base64EncodedString()
        var queryItems = [URLQueryItem(name: "name", value: encodedName)]
        if let token {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw SamsungConnectionError.invalidEndpoint
        }
        return url
    }
}
