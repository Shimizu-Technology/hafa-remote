import Foundation
import Testing

@testable import HafaRemote

struct VizioProtocolCodecTests {
    @Test("Every remote action maps to one reviewed Vizio keypress")
    func encodesRemoteCommands() throws {
        let expected: [RemoteCommand: (Int, Int)] = [
            .powerOff: (11, 0),
            .up: (3, 8),
            .down: (3, 0),
            .left: (3, 1),
            .right: (3, 7),
            .select: (3, 2),
            .home: (4, 15),
            .back: (4, 0),
            .play: (2, 3),
            .pause: (2, 2),
            .rewind: (2, 1),
            .fastForward: (2, 0),
            .volumeUp: (5, 1),
            .volumeDown: (5, 0),
            .mute: (5, 4),
        ]

        #expect(expected.count == RemoteCommand.allCases.count)
        for command in RemoteCommand.allCases {
            let object = try jsonObject(VizioProtocolCodec.remoteCommand(command))
            let keys = try #require(object["KEYLIST"] as? [[String: Any]])
            let key = try #require(keys.first)
            let mapping = try #require(expected[command])

            #expect(keys.count == 1)
            #expect(key["CODESET"] as? Int == mapping.0)
            #expect(key["CODE"] as? Int == mapping.1)
            #expect(key["ACTION"] as? String == "KEYPRESS")
        }
    }

    @Test("Pairing requests contain only the stable client identity and PIN ceremony fields")
    func encodesPairingRequests() throws {
        let clientID = "00000000-0000-4000-8000-000000000001"
        let begin = try jsonObject(VizioProtocolCodec.beginPairing(deviceID: clientID))
        let finish = try jsonObject(
            VizioProtocolCodec.finishPairing(
                deviceID: clientID,
                challenge: VizioPairingChallenge(challengeType: 1, requestToken: 42),
                pin: "1234"
            )
        )

        #expect(begin["DEVICE_ID"] as? String == clientID)
        #expect(begin["DEVICE_NAME"] as? String == "Hafa Remote")
        #expect(finish["DEVICE_ID"] as? String == clientID)
        #expect(finish["CHALLENGE_TYPE"] as? Int == 1)
        #expect(finish["PAIRING_REQ_TOKEN"] as? Int == 42)
        #expect(finish["RESPONSE_VALUE"] as? String == "1234")
        #expect(throws: VizioProtocolError.invalidResponse) {
            try VizioProtocolCodec.finishPairing(
                deviceID: clientID,
                challenge: VizioPairingChallenge(challengeType: 1, requestToken: 42),
                pin: "12A4"
            )
        }
    }

    @Test("Pairing responses expose only the challenge and auth token")
    func decodesPairingResponses() throws {
        let challenge = Data(
            #"{"STATUS":{"RESULT":"SUCCESS","DETAIL":"ignored"},"ITEM":{"CHALLENGE_TYPE":1,"PAIRING_REQ_TOKEN":42,"DEVICE_NAME":"ignored"}}"#
                .utf8
        )
        let token = Data(
            #"{"STATUS":{"RESULT":"SUCCESS"},"ITEM":{"AUTH_TOKEN":" synthetic-token ","EXTRA":"ignored"}}"#
                .utf8
        )

        #expect(
            try VizioProtocolCodec.pairingChallenge(from: challenge)
                == VizioPairingChallenge(challengeType: 1, requestToken: 42)
        )
        #expect(try VizioProtocolCodec.authToken(from: token) == "synthetic-token")
    }

    @Test("Device failures remain typed and never become success")
    func rejectsFailureResponses() {
        let rejected = Data(#"{"STATUS":{"RESULT":"PAIRING_DENIED"}}"#.utf8)

        #expect(throws: VizioProtocolError.rejected("PAIRING_DENIED")) {
            try VizioProtocolCodec.requireSuccess(from: rejected)
        }
        #expect(throws: VizioProtocolError.invalidResponse) {
            try VizioProtocolCodec.requireSuccess(from: Data(#"{"ITEM":{}}"#.utf8))
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

struct VizioPairingCredentialTests {
    @Test("Credentials and TV identity validate and redact secret material")
    func validatesCredential() throws {
        let token = "synthetic-secret-token"
        let credential = try VizioPairingCredential(
            authToken: token,
            certificateSHA256: Data(repeating: 1, count: 32),
            clientID: "00000000-0000-4000-8000-000000000001"
        )
        let identity = try VizioPairingIdentity(reportedDeviceID: " synthetic-vizio-id ")

        #expect(credential.authToken == token)
        #expect(!String(describing: credential).contains(token))
        #expect(identity.reportedDeviceID == "synthetic-vizio-id")
        #expect(identity.stableDeviceKey == "vizio:synthetic-vizio-id")
        #expect(!String(describing: identity).contains("synthetic-vizio-id"))
    }

    @Test("Malformed credential fields are rejected")
    func rejectsMalformedCredential() {
        #expect(throws: VizioPairingCredentialError.invalidAuthToken) {
            try VizioPairingCredential(
                authToken: "",
                certificateSHA256: Data(repeating: 1, count: 32),
                clientID: UUID().uuidString
            )
        }
        #expect(throws: VizioPairingCredentialError.invalidCertificateFingerprint) {
            try VizioPairingCredential(
                authToken: "token",
                certificateSHA256: Data(repeating: 1, count: 31),
                clientID: UUID().uuidString
            )
        }
        #expect(throws: VizioPairingCredentialError.invalidClientID) {
            try VizioPairingCredential(
                authToken: "token",
                certificateSHA256: Data(repeating: 1, count: 32),
                clientID: "shared-client"
            )
        }
    }
}

struct VizioTrustPolicyTests {
    @Test("First pairing trusts one certificate only at the selected private endpoint")
    func scopesFirstPairingTrust() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let first = Data(repeating: 1, count: 32)
        let changed = Data(repeating: 2, count: 32)
        var policy = VizioTrustPolicy(
            address: address,
            port: 7345,
            mode: .selectedPairingCandidate
        )

        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 7345,
                presentedFingerprint: first
            ) == .accept
        )
        #expect(
            policy.evaluate(
                host: address.rawValue,
                port: 7345,
                presentedFingerprint: changed
            ) == .reject(.certificateChanged)
        )
        #expect(
            policy.evaluate(host: "192.168.10.21", port: 7345, presentedFingerprint: first)
                == .reject(.unexpectedEndpoint)
        )
        #expect(
            policy.evaluate(host: address.rawValue, port: 9000, presentedFingerprint: first)
                == .reject(.unexpectedEndpoint)
        )
    }

    @Test("Reconnect accepts only the saved certificate fingerprint")
    func pinsReconnectCertificate() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let saved = Data(repeating: 3, count: 32)
        var matching = VizioTrustPolicy(
            address: address,
            port: 9000,
            mode: .reconnect(expectedFingerprint: saved)
        )
        var changed = matching

        #expect(
            matching.evaluate(
                host: address.rawValue,
                port: 9000,
                presentedFingerprint: saved
            ) == .accept
        )
        #expect(
            changed.evaluate(
                host: address.rawValue,
                port: 9000,
                presentedFingerprint: Data(repeating: 4, count: 32)
            ) == .reject(.certificateChanged)
        )
    }
}
