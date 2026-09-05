import Foundation
import Testing

@testable import HafaRemote

struct SonyTLSChannelTests {
    @Test("Certificate subjects expose the TV name without its network identifier")
    func sanitizesCertificateDisplayName() {
        let subject = "atvremote/bravia/bravia/Living Room Sony/AA:BB:CC:DD:EE:FF"

        #expect(SonyCertificateDisplayName.make(from: subject) == "Living Room Sony")
        #expect(SonyCertificateDisplayName.make(from: nil) == "Sony / Google TV")
        #expect(!SonyCertificateDisplayName.make(from: subject).contains("AA:BB"))
        #expect(SonyCertificateDisplayName.make(from: "AA-BB-CC-DD-EE-FF") == "Sony / Google TV")
    }

    @Test("A selected pairing candidate pins one certificate for the whole connection")
    func pairingCandidateUsesOneCertificate() {
        let first = Data(repeating: 1, count: 32)
        let second = Data(repeating: 2, count: 32)
        var policy = SonyTLSTrustPolicy(mode: .selectedPairingCandidate)

        #expect(policy.evaluate(fingerprint: first) == .accept)
        #expect(policy.evaluate(fingerprint: first) == .accept)
        #expect(policy.evaluate(fingerprint: second) == .reject(.certificateChanged))
        #expect(policy.candidateFingerprint == first)
    }

    @Test("A reconnect accepts only the previously paired certificate")
    func reconnectRequiresSavedCertificate() {
        let saved = Data(repeating: 3, count: 32)
        let changed = Data(repeating: 4, count: 32)
        var accepted = SonyTLSTrustPolicy(mode: .reconnect(expectedCertificateSHA256: saved))
        var rejected = SonyTLSTrustPolicy(mode: .reconnect(expectedCertificateSHA256: saved))

        #expect(accepted.evaluate(fingerprint: saved) == .accept)
        #expect(rejected.evaluate(fingerprint: changed) == .reject(.certificateChanged))
        #expect(rejected.candidateFingerprint == nil)
    }

    @Test("Disconnect reset drops every message from the prior TLS connection")
    func resetDropsPriorMessages() throws {
        let first = Data([1, 2, 3])
        let second = Data([4, 5, 6])
        var buffer = SonyTLSMessageBuffer()

        #expect(
            try buffer.append(SonyProtobuf.framed(first) + SonyProtobuf.framed(second)) == first
        )
        buffer.reset()

        #expect(buffer.next() == nil)
        #expect(try buffer.append(SonyProtobuf.framed(Data([7]))) == Data([7]))
        #expect(buffer.next() == nil)
    }

    @Test("A late read from an old connection cannot enter the replacement connection buffer")
    func lateReadCannotCrossReconnectBoundary() async throws {
        let first = SonyTestConnection()
        let second = SonyTestConnection()
        let receiver = ControllableSonyChunkReceiver()
        let harness = SonyReceiveIsolationHarness(connection: first)
        let task = Task {
            try await harness.receive(expectedConnection: first) {
                try await receiver.receive()
            }
        }

        await receiver.waitUntilReceiving()
        await harness.replaceConnection(with: second)
        await receiver.resume(with: try SonyProtobuf.framed(Data([9, 8, 7])))

        await #expect(throws: SonyTLSChannelError.connectionClosed) {
            try await task.value
        }
        #expect(await harness.nextBufferedMessage() == nil)
    }

    @Test("Cancelling a TLS connection deadline preserves cancellation")
    func connectionDeadlinePreservesCancellation() async {
        let task = Task {
            try await SonyTLSConnectionDeadline.run(timeout: .seconds(30)) {
                try await Task.sleep(for: .seconds(30))
                return true
            }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("A stalled TLS connection reaches its typed deadline")
    func connectionDeadlineTimesOut() async {
        await #expect(throws: SonyTLSChannelError.timedOut) {
            try await SonyTLSConnectionDeadline.run(timeout: .milliseconds(20)) {
                try await Task.sleep(for: .seconds(1))
                return true
            }
        }
    }

    @Test("A stalled remote handshake becomes the coordinator timeout state")
    func remoteHandshakeTimesOut() async {
        await #expect(throws: SonyPairingCoordinatorError.remoteHandshakeTimedOut) {
            try await SonyRemoteHandshake.run(
                on: StalledSonyTLSChannel(),
                fallbackModelName: "Sony TV",
                timeout: .milliseconds(20),
                maximumMessages: 8
            )
        }
    }

    @Test("A stalled pairing exchange becomes the coordinator pairing timeout state")
    func pairingExchangeTimesOut() async {
        await #expect(throws: SonyPairingCoordinatorError.pairingTimedOut) {
            try await SonyPairingExchangeDeadline.run(timeout: .milliseconds(20)) {
                try await Task.sleep(for: .seconds(1))
                return true
            }
        }
    }
}

private final class SonyTestConnection: @unchecked Sendable {
    deinit {}
}

private actor SonyReceiveIsolationHarness {
    private var connection: SonyTestConnection?
    private var buffer = SonyTLSMessageBuffer()

    init(connection: SonyTestConnection) {
        self.connection = connection
    }

    func receive(
        expectedConnection: SonyTestConnection,
        receiveChunk: @Sendable () async throws -> Data
    ) async throws -> Data? {
        let chunk = try await receiveChunk()
        return try SonyTLSReceivedChunkIsolation.append(
            chunk,
            expectedConnection: expectedConnection,
            currentConnection: connection,
            to: &buffer
        )
    }

    func replaceConnection(with connection: SonyTestConnection) {
        self.connection = connection
        buffer.reset()
    }

    func nextBufferedMessage() -> Data? {
        buffer.next()
    }
}

private actor ControllableSonyChunkReceiver {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var chunkContinuation: CheckedContinuation<Data, Error>?
    private var isReceiving = false

    func receive() async throws -> Data {
        isReceiving = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            chunkContinuation = continuation
        }
    }

    func waitUntilReceiving() async {
        guard !isReceiving else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func resume(with chunk: Data) {
        chunkContinuation?.resume(returning: chunk)
        chunkContinuation = nil
    }
}

private actor StalledSonyTLSChannel: SonyTLSChanneling {
    func connect(
        address: PrivateIPv4Address,
        port: UInt16,
        identity: SonyClientIdentityReference,
        trustMode: SonyTLSTrustMode
    ) async throws -> SonyTLSPeer {
        throw SonyTLSChannelError.unavailable
    }

    func send(_ message: Data) async throws {}

    func receive() async throws -> Data {
        try await Task.sleep(for: .seconds(1))
        return Data()
    }

    func disconnect() async {}
}
