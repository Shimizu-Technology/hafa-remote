import Foundation
import Testing

@testable import HafaRemote

struct SonyProtocolCodecTests {
    @Test("Length-delimited decoding handles split and coalesced network reads")
    func decodesFragmentedAndCoalescedFrames() throws {
        let first = SonyProtobuf.stringField(1, "first")
        let second = SonyProtobuf.stringField(2, "second")
        let bytes = try SonyProtobuf.framed(first) + SonyProtobuf.framed(second)
        var decoder = SonyDelimitedMessageDecoder()

        #expect(try decoder.append(Data(bytes.prefix(2))).isEmpty)
        let messages = try decoder.append(Data(bytes.dropFirst(2)))

        #expect(messages == [first, second])
    }

    @Test("Malformed and oversized protobuf input is rejected")
    func rejectsInvalidInput() throws {
        var decoder = SonyDelimitedMessageDecoder()
        let oversizedLength = SonyProtobuf.varint(UInt64(SonyProtobuf.maximumMessageSize + 1))

        #expect(throws: SonyProtocolCodecError.messageTooLarge) {
            try decoder.append(oversizedLength)
        }
        #expect(throws: SonyProtocolCodecError.malformedProtobuf) {
            try SonyProtobuf.fields(in: Data([0x0F]))
        }
    }

    @Test("Pairing requests contain only the expected service and bounded client name")
    func encodesPairingRequest() throws {
        let request = SonyPairingProtocolCodec.request(clientName: String(repeating: "A", count: 100))
        let outer = try SonyProtobuf.fields(in: request)
        let requestBytes = try #require(outer.first(where: { $0.number == 10 })?.bytes)
        let requestFields = try SonyProtobuf.fields(in: requestBytes)

        #expect(outer.first(where: { $0.number == 1 })?.varint == 2)
        #expect(outer.first(where: { $0.number == 2 })?.varint == 200)
        #expect(String(decoding: try #require(requestFields[0].bytes), as: UTF8.self) == "atvremote")
        #expect(try #require(requestFields[1].bytes).count == 80)
    }

    @Test("Pairing handshake responses are classified and rejected by status")
    func parsesPairingHandshakeResponses() throws {
        func response(field: Int) -> Data {
            SonyProtobuf.varintField(1, 2)
                + SonyProtobuf.varintField(2, 200)
                + SonyProtobuf.bytesField(field, Data())
        }
        let rejection =
            SonyProtobuf.varintField(1, 2)
            + SonyProtobuf.varintField(2, 402)

        #expect(try SonyPairingProtocolCodec.parse(response(field: 11)) == .requestAcknowledged)
        #expect(try SonyPairingProtocolCodec.parse(response(field: 20)) == .options)
        #expect(try SonyPairingProtocolCodec.parse(response(field: 31)) == .configurationAcknowledged)
        #expect(try SonyPairingProtocolCodec.parse(response(field: 41)) == .secretAcknowledged)
        #expect(throws: SonyProtocolCodecError.pairingRejected(402)) {
            try SonyPairingProtocolCodec.parse(rejection)
        }
    }

    @Test("The pairing secret accepts only a complete SHA-256 digest")
    func encodesPairingSecret() throws {
        let digest = Data(repeating: 0xA5, count: 32)
        let message = try SonyPairingProtocolCodec.secret(digest)
        let outer = try SonyProtobuf.fields(in: message)
        let secret = try #require(outer.first(where: { $0.number == 40 })?.bytes)
        let secretFields = try SonyProtobuf.fields(in: secret)

        #expect(secretFields.first(where: { $0.number == 1 })?.bytes == digest)
        #expect(throws: SonyProtocolCodecError.malformedProtobuf) {
            try SonyPairingProtocolCodec.secret(Data(repeating: 0, count: 31))
        }
        #expect(throws: SonyProtocolCodecError.malformedProtobuf) {
            try SonyPairingProtocolCodec.secret(Data(repeating: 0, count: 33))
        }
    }

    @Test("Every semantic remote command maps to one short Android key injection")
    func mapsSemanticCommands() throws {
        for command in RemoteCommand.allCases {
            let message = try SonyRemoteProtocolCodec.command(command)
            let keyMessage = try #require(
                SonyProtobuf.fields(in: message).first(where: { $0.number == 10 })?.bytes
            )
            let fields = try SonyProtobuf.fields(in: keyMessage)
            #expect(fields.first(where: { $0.number == 1 })?.varint == expectedCode(for: command))
            #expect(fields.first(where: { $0.number == 2 })?.varint == 3)
        }
    }

    @Test("Configure, ping, and power messages expose only needed Sony session state")
    func parsesRemoteEvents() throws {
        let device =
            SonyProtobuf.stringField(1, "BRAVIA TEST")
            + SonyProtobuf.stringField(2, "Sony")
            + SonyProtobuf.stringField(6, "12.34")
        let configure =
            SonyProtobuf.varintField(1, 99)
            + SonyProtobuf.bytesField(2, device)
        let configureMessage = SonyProtobuf.bytesField(1, configure)
        let pingMessage = SonyProtobuf.bytesField(8, SonyProtobuf.varintField(1, 42))
        let powerMessage = SonyProtobuf.bytesField(40, SonyProtobuf.varintField(1, 1))

        #expect(
            try SonyRemoteProtocolCodec.parse(configureMessage)
                == .configured(
                    vendor: "Sony",
                    model: "BRAVIA TEST",
                    softwareVersion: "12.34",
                    supportedFeatures: 99
                )
        )
        #expect(
            try SonyRemoteProtocolCodec.parse(SonyProtobuf.bytesField(2, Data())) == .setActive
        )
        let deviceWithoutVersion =
            SonyProtobuf.stringField(1, "BRAVIA TEST")
            + SonyProtobuf.stringField(2, "Sony")
        let configureWithoutVersion = SonyProtobuf.bytesField(
            1,
            SonyProtobuf.varintField(1, 99)
                + SonyProtobuf.bytesField(2, deviceWithoutVersion)
        )
        #expect(
            try SonyRemoteProtocolCodec.parse(configureWithoutVersion)
                == .configured(
                    vendor: "Sony",
                    model: "BRAVIA TEST",
                    softwareVersion: "",
                    supportedFeatures: 99
                )
        )
        #expect(try SonyRemoteProtocolCodec.parse(pingMessage) == .ping(42))
        #expect(try SonyRemoteProtocolCodec.parse(powerMessage) == .powerState(true))
    }

    /// Returns the protocol key expected for each product-level command.
    private func expectedCode(for command: RemoteCommand) -> UInt64 {
        switch command {
        case .powerOn: 224
        case .powerOff: 223
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .select: 23
        case .home: 3
        case .back: 4
        case .play: 126
        case .pause: 127
        case .rewind: 89
        case .fastForward: 90
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        }
    }
}
