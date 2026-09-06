import Foundation

enum SonyProtocolCodecError: Error, Equatable, Sendable {
    case malformedProtobuf
    case messageTooLarge
    case unsupportedCommand
    case pairingRejected(UInt64)
}

struct SonyProtobufField: Equatable, Sendable {
    let number: Int
    let wireType: UInt8
    let varint: UInt64?
    let bytes: Data?
}

enum SonyProtobuf {
    static let maximumMessageSize = 1_048_576

    static func varint(_ value: UInt64) -> Data {
        var value = value
        var encoded = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            encoded.append(byte)
        } while value != 0
        return encoded
    }

    static func varintField(_ number: Int, _ value: UInt64) -> Data {
        varint(UInt64(number << 3)) + varint(value)
    }

    static func bytesField(_ number: Int, _ value: Data) -> Data {
        varint(UInt64((number << 3) | 2)) + varint(UInt64(value.count)) + value
    }

    static func stringField(_ number: Int, _ value: String) -> Data {
        bytesField(number, Data(value.utf8))
    }

    static func fields(in data: Data) throws -> [SonyProtobufField] {
        guard data.count <= maximumMessageSize else {
            throw SonyProtocolCodecError.messageTooLarge
        }
        var index = data.startIndex
        var fields: [SonyProtobufField] = []
        while index < data.endIndex {
            let key = try decodeVarint(in: data, index: &index)
            let number = Int(key >> 3)
            let wireType = UInt8(key & 0x07)
            guard number > 0 else { throw SonyProtocolCodecError.malformedProtobuf }
            switch wireType {
            case 0:
                fields.append(
                    SonyProtobufField(
                        number: number,
                        wireType: wireType,
                        varint: try decodeVarint(in: data, index: &index),
                        bytes: nil
                    )
                )
            case 1:
                guard data.distance(from: index, to: data.endIndex) >= 8 else {
                    throw SonyProtocolCodecError.malformedProtobuf
                }
                index = data.index(index, offsetBy: 8)
            case 2:
                let length = try decodeVarint(in: data, index: &index)
                guard length <= UInt64(maximumMessageSize),
                    let count = Int(exactly: length),
                    data.distance(from: index, to: data.endIndex) >= count
                else {
                    throw SonyProtocolCodecError.malformedProtobuf
                }
                let end = data.index(index, offsetBy: count)
                fields.append(
                    SonyProtobufField(
                        number: number,
                        wireType: wireType,
                        varint: nil,
                        bytes: data[index..<end]
                    )
                )
                index = end
            case 5:
                guard data.distance(from: index, to: data.endIndex) >= 4 else {
                    throw SonyProtocolCodecError.malformedProtobuf
                }
                index = data.index(index, offsetBy: 4)
            default:
                throw SonyProtocolCodecError.malformedProtobuf
            }
        }
        return fields
    }

    static func framed(_ message: Data) throws -> Data {
        guard message.count <= maximumMessageSize else {
            throw SonyProtocolCodecError.messageTooLarge
        }
        return varint(UInt64(message.count)) + message
    }

    private static func decodeVarint(in data: Data, index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < data.endIndex else {
                throw SonyProtocolCodecError.malformedProtobuf
            }
            let byte = data[index]
            index = data.index(after: index)
            if shift == 63, byte > 1 {
                throw SonyProtocolCodecError.malformedProtobuf
            }
            result |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw SonyProtocolCodecError.malformedProtobuf
    }
}

struct SonyDelimitedMessageDecoder: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= SonyProtobuf.maximumMessageSize + 10 else {
            throw SonyProtocolCodecError.messageTooLarge
        }

        var messages: [Data] = []
        while !buffer.isEmpty {
            guard let prefix = try lengthPrefix(in: buffer) else { break }
            guard prefix.length <= SonyProtobuf.maximumMessageSize else {
                throw SonyProtocolCodecError.messageTooLarge
            }
            let totalLength = prefix.byteCount + prefix.length
            guard buffer.count >= totalLength else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: prefix.byteCount)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: totalLength)
            messages.append(Data(buffer[payloadStart..<payloadEnd]))
            buffer.removeFirst(totalLength)
        }
        return messages
    }

    private func lengthPrefix(in data: Data) throws -> (length: Int, byteCount: Int)? {
        var result: UInt64 = 0
        for (offset, byte) in data.prefix(10).enumerated() {
            let shift = offset * 7
            if shift == 63, byte > 1 {
                throw SonyProtocolCodecError.malformedProtobuf
            }
            result |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 {
                guard let length = Int(exactly: result) else {
                    throw SonyProtocolCodecError.messageTooLarge
                }
                return (length, offset + 1)
            }
        }
        if data.count >= 10 { throw SonyProtocolCodecError.malformedProtobuf }
        return nil
    }
}

enum SonyPairingMessage: Equatable, Sendable {
    case requestAcknowledged
    case options
    case configurationAcknowledged
    case secretAcknowledged
}

enum SonyPairingProtocolCodec {
    static func request(clientName: String) -> Data {
        outer(
            fieldNumber: 10,
            payload:
                SonyProtobuf.stringField(1, "atvremote")
                + SonyProtobuf.stringField(2, String(clientName.prefix(80)))
        )
    }

    static func options() -> Data {
        let encoding =
            SonyProtobuf.varintField(1, 3)
            + SonyProtobuf.varintField(2, 6)
        let payload =
            SonyProtobuf.bytesField(1, encoding)
            + SonyProtobuf.varintField(3, 1)
        return outer(fieldNumber: 20, payload: payload)
    }

    static func configuration() -> Data {
        let encoding =
            SonyProtobuf.varintField(1, 3)
            + SonyProtobuf.varintField(2, 6)
        let payload =
            SonyProtobuf.bytesField(1, encoding)
            + SonyProtobuf.varintField(2, 1)
        return outer(fieldNumber: 30, payload: payload)
    }

    static func secret(_ digest: Data) throws -> Data {
        guard digest.count == 32 else { throw SonyProtocolCodecError.malformedProtobuf }
        return outer(fieldNumber: 40, payload: SonyProtobuf.bytesField(1, digest))
    }

    static func parse(_ data: Data) throws -> SonyPairingMessage {
        let fields = try SonyProtobuf.fields(in: data)
        let status = fields.first(where: { $0.number == 2 })?.varint
        guard status == 200 else {
            throw SonyProtocolCodecError.pairingRejected(status ?? 0)
        }
        if fields.contains(where: { $0.number == 11 }) { return .requestAcknowledged }
        if fields.contains(where: { $0.number == 20 }) { return .options }
        if fields.contains(where: { $0.number == 31 }) { return .configurationAcknowledged }
        if fields.contains(where: { $0.number == 41 }) { return .secretAcknowledged }
        throw SonyProtocolCodecError.malformedProtobuf
    }

    private static func outer(fieldNumber: Int, payload: Data) -> Data {
        SonyProtobuf.varintField(1, 2)
            + SonyProtobuf.varintField(2, 200)
            + SonyProtobuf.bytesField(fieldNumber, payload)
    }
}

enum SonyRemoteEvent: Equatable, Sendable {
    case configured(vendor: String, model: String, softwareVersion: String, supportedFeatures: UInt64)
    case setActive
    case ping(Int64)
    case powerState(Bool)
    case other
}

enum SonyRemoteProtocolCodec {
    private static let activeFeatures: UInt64 = 1 | 2 | 32 | 64

    static func configurationResponse() -> Data {
        let deviceInfo =
            SonyProtobuf.stringField(1, "Hafa Remote")
            + SonyProtobuf.stringField(2, "Shimizu Technology")
            + SonyProtobuf.varintField(3, 1)
            + SonyProtobuf.stringField(4, "1")
            + SonyProtobuf.stringField(5, "com.shimizutechnology.hafaremote")
            + SonyProtobuf.stringField(6, "1.0")
        let configuration =
            SonyProtobuf.varintField(1, activeFeatures)
            + SonyProtobuf.bytesField(2, deviceInfo)
        return SonyProtobuf.bytesField(1, configuration)
    }

    static func activeResponse() -> Data {
        SonyProtobuf.bytesField(2, SonyProtobuf.varintField(1, activeFeatures))
    }

    static func pingResponse(_ value: Int64) -> Data {
        SonyProtobuf.bytesField(9, SonyProtobuf.varintField(1, UInt64(bitPattern: value)))
    }

    static func command(_ command: RemoteCommand) throws -> Data {
        let keyCode: UInt64
        switch command {
        case .up: keyCode = 19
        case .down: keyCode = 20
        case .left: keyCode = 21
        case .right: keyCode = 22
        case .select: keyCode = 23
        case .volumeUp: keyCode = 24
        case .volumeDown: keyCode = 25
        case .home: keyCode = 3
        case .back: keyCode = 4
        case .play: keyCode = 126
        case .pause: keyCode = 127
        case .rewind: keyCode = 89
        case .fastForward: keyCode = 90
        case .mute: keyCode = 164
        case .powerOn: keyCode = 224
        case .powerOff: keyCode = 223
        }
        let key =
            SonyProtobuf.varintField(1, keyCode)
            + SonyProtobuf.varintField(2, 3)
        return SonyProtobuf.bytesField(10, key)
    }

    static func parse(_ data: Data) throws -> SonyRemoteEvent {
        let fields = try SonyProtobuf.fields(in: data)
        if let configure = fields.first(where: { $0.number == 1 })?.bytes {
            let configureFields = try SonyProtobuf.fields(in: configure)
            let features = configureFields.first(where: { $0.number == 1 })?.varint ?? 0
            guard let deviceInfo = configureFields.first(where: { $0.number == 2 })?.bytes else {
                throw SonyProtocolCodecError.malformedProtobuf
            }
            let deviceFields = try SonyProtobuf.fields(in: deviceInfo)
            return .configured(
                vendor: string(field: 2, in: deviceFields),
                model: string(field: 1, in: deviceFields),
                softwareVersion: string(field: 6, in: deviceFields),
                supportedFeatures: features
            )
        }
        if fields.contains(where: { $0.number == 2 }) {
            return .setActive
        }
        if let ping = fields.first(where: { $0.number == 8 })?.bytes {
            let value = try SonyProtobuf.fields(in: ping).first(where: { $0.number == 1 })?.varint ?? 0
            return .ping(Int64(bitPattern: value))
        }
        if let start = fields.first(where: { $0.number == 40 })?.bytes {
            let value = try SonyProtobuf.fields(in: start).first(where: { $0.number == 1 })?.varint
            return .powerState(value == 1)
        }
        return .other
    }

    private static func string(field number: Int, in fields: [SonyProtobufField]) -> String {
        guard let data = fields.first(where: { $0.number == number })?.bytes else { return "" }
        return String(decoding: Data(data.prefix(80)), as: UTF8.self)
    }
}
