import Foundation
@preconcurrency import Network

/// A validated unicast hardware address used only for local-network wake requests.
struct SamsungMACAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    let octets: [UInt8]

    init(_ value: String) throws {
        let compact = value.filter { $0 != ":" && $0 != "-" }
        guard compact.count == 12, compact.allSatisfy(\.isHexDigit) else {
            throw SamsungMACAddressError.invalid
        }

        var parsed: [UInt8] = []
        parsed.reserveCapacity(6)
        var index = compact.startIndex
        for _ in 0..<6 {
            let next = compact.index(index, offsetBy: 2)
            guard let octet = UInt8(compact[index..<next], radix: 16) else {
                throw SamsungMACAddressError.invalid
            }
            parsed.append(octet)
            index = next
        }

        guard
            parsed.contains(where: { $0 != 0 }),
            parsed.contains(where: { $0 != 0xFF }),
            parsed[0] & 1 == 0
        else {
            throw SamsungMACAddressError.invalid
        }
        octets = parsed
    }

    var persistedValue: String {
        octets.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    var description: String {
        "SamsungMACAddress(redacted)"
    }
}

enum SamsungMACAddressError: LocalizedError, Equatable, Sendable {
    case invalid

    var errorDescription: String? {
        "The TV did not provide a usable network address for power on."
    }
}

enum SamsungWakeOnLANError: LocalizedError, Equatable, Sendable {
    case signalNotSent

    var errorDescription: String? {
        "Hafa Remote could not send the wake signal. Check Wi-Fi and try again."
    }
}

protocol SamsungWakePacketSending: Sendable {
    func send(_ packet: Data, to address: PrivateIPv4Address, port: UInt16) async throws
}

protocol SamsungTVWaking: Sendable {
    func wake(_ macAddress: SamsungMACAddress, at address: PrivateIPv4Address) async throws
}

/// Sends the standard Wake-on-LAN magic packet to the saved TV address.
///
/// This first release deliberately uses UDP unicast, which Apple permits under
/// normal local-network privacy. A subnet broadcast must not be added until
/// Apple grants the multicast networking entitlement.
actor SamsungWakeOnLANService: SamsungTVWaking {
    private static let discardPort: UInt16 = 9
    private static let repetitionCount = 3
    private static let sendTimeout: Duration = .seconds(2)

    private let sender: any SamsungWakePacketSending

    init(sender: any SamsungWakePacketSending = NetworkSamsungWakePacketSender()) {
        self.sender = sender
    }

    func wake(_ macAddress: SamsungMACAddress, at address: PrivateIPv4Address) async throws {
        let packet = Self.magicPacket(for: macAddress)
        do {
            for attempt in 0..<Self.repetitionCount {
                try Task.checkCancellation()
                try await sendWithinTimeout(packet, to: address)
                if attempt < Self.repetitionCount - 1 {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SamsungWakeOnLANError.signalNotSent
        }
    }

    static func magicPacket(for macAddress: SamsungMACAddress) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 6)
        bytes.reserveCapacity(102)
        for _ in 0..<16 {
            bytes.append(contentsOf: macAddress.octets)
        }
        return Data(bytes)
    }

    private func sendWithinTimeout(_ packet: Data, to address: PrivateIPv4Address) async throws {
        let sender = sender
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await sender.send(packet, to: address, port: Self.discardPort)
            }
            group.addTask {
                try await Task.sleep(for: Self.sendTimeout)
                throw SamsungWakeOnLANError.signalNotSent
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

struct NetworkSamsungWakePacketSender: SamsungWakePacketSending {
    func send(_ packet: Data, to address: PrivateIPv4Address, port: UInt16) async throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw SamsungWakeOnLANError.signalNotSent
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(address.rawValue),
            port: networkPort,
            using: .udp
        )
        let completion = SamsungWakeSendCompletion()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(
                            content: packet,
                            completion: .contentProcessed { error in
                                connection.cancel()
                                if let error {
                                    completion.resume(throwing: error)
                                } else {
                                    completion.resume()
                                }
                            })
                    case .failed(let error):
                        connection.cancel()
                        completion.resume(throwing: error)
                    case .cancelled:
                        completion.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "com.shimizutechnology.hafaremote.wake"))
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class SamsungWakeSendCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let pendingResult {
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        finish(with: .success(()))
    }

    func resume(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        guard pendingResult == nil else {
            lock.unlock()
            return
        }
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        pendingResult = result
        lock.unlock()
        continuation.resume(with: result)
    }
}
