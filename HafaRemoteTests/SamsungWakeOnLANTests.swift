import Foundation
import Testing

@testable import HafaRemote

struct SamsungWakeOnLANTests {
    @Test("MAC addresses accept common separators and persist canonically")
    func parsesMACAddresses() throws {
        let colon = try SamsungMACAddress("02:00:5e:10:00:01")
        let hyphen = try SamsungMACAddress("02-00-5E-10-00-01")
        let compact = try SamsungMACAddress("02005E100001")

        #expect(colon == hyphen)
        #expect(hyphen == compact)
        #expect(colon.persistedValue == "02:00:5E:10:00:01")
        #expect(colon.description == "SamsungMACAddress(redacted)")
    }

    @Test(
        "MAC validation rejects malformed, zero, broadcast, and multicast addresses",
        arguments: [
            "", "02:00:5E:10:00", "02:00:5E:10:00:GG", "00:00:00:00:00:00",
            "FF:FF:FF:FF:FF:FF", "01:00:5E:10:00:01",
        ]
    )
    func rejectsUnsafeMACAddresses(_ value: String) {
        #expect(throws: SamsungMACAddressError.invalid) {
            try SamsungMACAddress(value)
        }
    }

    @Test("Magic packet contains the synchronization bytes and sixteen MAC copies")
    func buildsMagicPacket() throws {
        let macAddress = try SamsungMACAddress("02:00:5E:10:00:01")

        let packet = SamsungWakeOnLANService.magicPacket(for: macAddress)

        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))
        for copy in 0..<16 {
            let start = 6 + copy * 6
            #expect(Array(packet[start..<(start + 6)]) == macAddress.octets)
        }
    }

    @Test("Wake sends three identical unicast packets to the saved TV")
    func sendsRepeatedUnicastPackets() async throws {
        let sender = RecordingWakePacketSender()
        let service = SamsungWakeOnLANService(sender: sender)
        let macAddress = try SamsungMACAddress("02:00:5E:10:00:01")
        let address = try PrivateIPv4Address("192.168.10.25")

        try await service.wake(macAddress, at: address)

        let sends = await sender.sends
        #expect(sends.count == 3)
        #expect(Set(sends.map(\.packet)).count == 1)
        #expect(sends.allSatisfy { $0.address == address && $0.port == 9 })
    }

    @Test("Wake reports a generic failure without exposing network identifiers")
    func redactsSendFailure() async throws {
        let service = SamsungWakeOnLANService(sender: FailingWakePacketSender())
        let macAddress = try SamsungMACAddress("02:00:5E:10:00:01")
        let address = try PrivateIPv4Address("192.168.10.25")

        await #expect(throws: SamsungWakeOnLANError.signalNotSent) {
            try await service.wake(macAddress, at: address)
        }
        #expect(SamsungWakeOnLANError.signalNotSent.errorDescription?.contains("192") == false)
        #expect(SamsungWakeOnLANError.signalNotSent.errorDescription?.contains("02:00") == false)
    }

    @Test("Cancelling wake propagates cancellation")
    func cancellationPropagates() async throws {
        let sender = SuspendedWakePacketSender()
        let service = SamsungWakeOnLANService(sender: sender)
        let macAddress = try SamsungMACAddress("02:00:5E:10:00:01")
        let address = try PrivateIPv4Address("192.168.10.25")
        var starts = sender.starts.makeAsyncIterator()

        let wake = Task {
            try await service.wake(macAddress, at: address)
        }
        _ = await starts.next()
        wake.cancel()

        await #expect(throws: CancellationError.self) {
            try await wake.value
        }
    }

    @Test("A stalled send is bounded by the delivery timeout")
    func stalledSendTimesOut() async throws {
        let sender = SuspendedWakePacketSender()
        let service = SamsungWakeOnLANService(
            sender: sender,
            sendTimeout: .milliseconds(20)
        )
        let macAddress = try SamsungMACAddress("02:00:5E:10:00:01")
        let address = try PrivateIPv4Address("192.168.10.25")

        await #expect(throws: SamsungWakeOnLANError.signalNotSent) {
            try await service.wake(macAddress, at: address)
        }
    }
}

private actor RecordingWakePacketSender: SamsungWakePacketSending {
    struct Send: Equatable, Sendable {
        let packet: Data
        let address: PrivateIPv4Address
        let port: UInt16
    }

    private(set) var sends: [Send] = []

    func send(_ packet: Data, to address: PrivateIPv4Address, port: UInt16) {
        sends.append(Send(packet: packet, address: address, port: port))
    }
}

private struct FailingWakePacketSender: SamsungWakePacketSending {
    func send(_ packet: Data, to address: PrivateIPv4Address, port: UInt16) throws {
        throw SyntheticWakeError.failed
    }
}

private actor SuspendedWakePacketSender: SamsungWakePacketSending {
    nonisolated let starts: AsyncStream<Void>

    private let startContinuation: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (starts, startContinuation) = AsyncStream.makeStream()
        (releases, releaseContinuation) = AsyncStream.makeStream()
    }

    func release() {
        releaseContinuation.yield()
    }

    func send(_ packet: Data, to address: PrivateIPv4Address, port: UInt16) async throws {
        startContinuation.yield()
        for await _ in releases {
            break
        }
        try Task.checkCancellation()
    }
}

private enum SyntheticWakeError: Error {
    case failed
}
