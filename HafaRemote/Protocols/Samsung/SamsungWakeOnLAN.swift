import Foundation
@preconcurrency import Network

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

    private let sender: any SamsungWakePacketSending
    private let sendTimeout: Duration

    init(
        sender: any SamsungWakePacketSending = NetworkSamsungWakePacketSender(),
        sendTimeout: Duration = .seconds(2)
    ) {
        self.sender = sender
        self.sendTimeout = sendTimeout
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
        let sendTimeout = sendTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await sender.send(packet, to: address, port: Self.discardPort)
            }
            group.addTask {
                try await Task.sleep(for: sendTimeout)
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

    deinit {}

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
