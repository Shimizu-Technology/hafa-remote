import CryptoKit
import Foundation
@preconcurrency import Network
import Security

enum SonyTLSTrustMode: Equatable, Sendable {
    case selectedPairingCandidate
    case reconnect(expectedCertificateSHA256: Data)
}

enum SonyTLSChannelError: Error, Equatable, Sendable {
    case invalidIdentity
    case unavailable
    case missingCertificate
    case certificateChanged
    case invalidCertificate
    case connectionClosed
    case timedOut
}

enum SonyTLSTrustDecision: Equatable, Sendable {
    case accept
    case reject(SonyTLSChannelError)
}

struct SonyTLSTrustPolicy: Sendable {
    private let mode: SonyTLSTrustMode
    private(set) var candidateFingerprint: Data?

    init(mode: SonyTLSTrustMode) {
        self.mode = mode
    }

    mutating func evaluate(fingerprint: Data) -> SonyTLSTrustDecision {
        if case .reconnect(let expectedFingerprint) = mode,
            expectedFingerprint != fingerprint
        {
            return .reject(.certificateChanged)
        }
        if let candidateFingerprint, candidateFingerprint != fingerprint {
            return .reject(.certificateChanged)
        }
        candidateFingerprint = fingerprint
        return .accept
    }
}

struct SonyTLSPeer: Equatable, Sendable {
    let certificateDER: Data
    let certificateSHA256: Data
    let displayName: String
}

enum SonyCertificateDisplayName {
    static func make(from subject: String?) -> String {
        guard let subject else { return "Sony / Google TV" }
        let cleaned = String(
            String.UnicodeScalarView(
                subject.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            )
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let components = cleaned.split(separator: "/", omittingEmptySubsequences: true)
        let deviceName = components.count > 1 ? String(components[components.count - 2]) : cleaned
        let redacted = deviceName.replacingOccurrences(
            of: "(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? "Sony / Google TV" : String(redacted.prefix(80))
    }
}

struct SonyTLSMessageBuffer: Sendable {
    private var decoder = SonyDelimitedMessageDecoder()
    private var queuedMessages: [Data] = []

    mutating func next() -> Data? {
        queuedMessages.isEmpty ? nil : queuedMessages.removeFirst()
    }

    mutating func append(_ chunk: Data) throws -> Data? {
        let messages = try decoder.append(chunk)
        guard let first = messages.first else { return nil }
        queuedMessages.append(contentsOf: messages.dropFirst())
        return first
    }

    mutating func reset() {
        decoder = SonyDelimitedMessageDecoder()
        queuedMessages = []
    }
}

enum SonyTLSReceivedChunkIsolation {
    static func append<Connection: AnyObject>(
        _ chunk: Data,
        expectedConnection: Connection,
        currentConnection: Connection?,
        to buffer: inout SonyTLSMessageBuffer
    ) throws -> Data? {
        guard currentConnection === expectedConnection else {
            throw SonyTLSChannelError.connectionClosed
        }
        return try buffer.append(chunk)
    }
}

enum SonyTLSConnectionDeadline {
    static func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SonyTLSChannelError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw SonyTLSChannelError.connectionClosed
            }
            return result
        }
    }
}

protocol SonyTLSChanneling: Sendable {
    func connect(
        address: PrivateIPv4Address,
        port: UInt16,
        identity: SonyClientIdentityReference,
        trustMode: SonyTLSTrustMode
    ) async throws -> SonyTLSPeer
    func send(_ message: Data) async throws
    func receive() async throws -> Data
    func checkConnection() async throws
    func disconnect() async
}

extension SonyTLSChanneling {
    func checkConnection() async throws {}
}

/// Makes the non-Sendable Security identity safe to pass only as an immutable reference.
final class SonyClientIdentityReference: @unchecked Sendable {
    let value: SecIdentity

    init(_ value: SecIdentity) {
        self.value = value
    }
}

/// Owns one framed mutual-TLS connection to an Android TV Remote Service endpoint.
actor SonyTLSChannel: SonyTLSChanneling {
    private static let connectionTimeout: Duration = .seconds(10)

    private let queue = DispatchQueue(label: "com.shimizutechnology.hafaremote.sony-tls")
    private var connection: NWConnection?
    private var messageBuffer = SonyTLSMessageBuffer()

    func connect(
        address: PrivateIPv4Address,
        port: UInt16,
        identity: SonyClientIdentityReference,
        trustMode: SonyTLSTrustMode
    ) async throws -> SonyTLSPeer {
        disconnect()
        messageBuffer.reset()

        let tlsOptions = NWProtocolTLS.Options()
        guard let localIdentity = sec_identity_create(identity.value) else {
            throw SonyTLSChannelError.invalidIdentity
        }
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            localIdentity
        )
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        let peerCapture = SonyTLSPeerCapture(mode: trustMode)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trust, complete in
                complete(peerCapture.evaluate(trust: trust))
            },
            queue
        )

        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw SonyTLSChannelError.unavailable
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 10
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 2
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(
            host: NWEndpoint.Host(address.rawValue),
            port: networkPort,
            using: parameters
        )
        self.connection = connection

        do {
            try await SonyTLSConnectionDeadline.run(timeout: Self.connectionTimeout) {
                try await self.waitUntilReady(connection)
            }
            guard self.connection === connection else {
                throw SonyTLSChannelError.connectionClosed
            }
            guard let peer = peerCapture.peer else {
                throw peerCapture.failure ?? SonyTLSChannelError.missingCertificate
            }
            return peer
        } catch {
            if self.connection === connection {
                disconnect()
            } else {
                connection.cancel()
            }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            if let channelError = peerCapture.failure ?? error as? SonyTLSChannelError {
                throw channelError
            }
            throw SonyTLSChannelError.unavailable
        }
    }

    func send(_ message: Data) async throws {
        guard let connection else { throw SonyTLSChannelError.connectionClosed }
        let framed = try SonyProtobuf.framed(message)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: framed,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receive() async throws -> Data {
        if let queued = messageBuffer.next() { return queued }
        guard let connection else { throw SonyTLSChannelError.connectionClosed }

        while true {
            let chunk = try await receiveChunk(on: connection)
            if let message = try SonyTLSReceivedChunkIsolation.append(
                chunk,
                expectedConnection: connection,
                currentConnection: self.connection,
                to: &messageBuffer
            ) {
                return message
            }
        }
    }

    func checkConnection() throws {
        guard let connection else { throw SonyTLSChannelError.connectionClosed }
        switch connection.state {
        case .ready:
            return
        case .setup, .preparing, .waiting:
            throw SonyTLSChannelError.unavailable
        case .failed, .cancelled:
            throw SonyTLSChannelError.connectionClosed
        @unknown default:
            throw SonyTLSChannelError.unavailable
        }
    }

    func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        messageBuffer.reset()
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = SonyConnectionContinuationGate(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume()
                    case .failed(let error):
                        gate.resume(throwing: error)
                    case .cancelled:
                        gate.resume(throwing: SonyTLSChannelError.connectionClosed)
                    case .setup, .preparing, .waiting:
                        break
                    @unknown default:
                        gate.resume(throwing: SonyTLSChannelError.unavailable)
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func receiveChunk(on connection: NWConnection) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 65_536
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: SonyTLSChannelError.connectionClosed)
                    } else {
                        continuation.resume(throwing: SonyTLSChannelError.unavailable)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class SonyConnectionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(throwing error: Error? = nil) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

private final class SonyTLSPeerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: SonyTLSTrustPolicy
    private var storedPeer: SonyTLSPeer?
    private var storedFailure: SonyTLSChannelError?

    init(mode: SonyTLSTrustMode) {
        policy = SonyTLSTrustPolicy(mode: mode)
    }

    var peer: SonyTLSPeer? { lock.withLock { storedPeer } }
    var failure: SonyTLSChannelError? { lock.withLock { storedFailure } }

    func evaluate(trust: sec_trust_t) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
            let certificate = chain.first
        else {
            return reject(.missingCertificate)
        }

        do {
            _ = try SonyRSAKeyComponents(certificate: certificate)
        } catch {
            return reject(.invalidCertificate)
        }

        let certificateDER = SecCertificateCopyData(certificate) as Data
        let fingerprint = Data(SHA256.hash(data: certificateDER))
        let peer = SonyTLSPeer(
            certificateDER: certificateDER,
            certificateSHA256: fingerprint,
            displayName: SonyCertificateDisplayName.make(
                from: SecCertificateCopySubjectSummary(certificate) as String?
            )
        )
        return lock.withLock {
            switch policy.evaluate(fingerprint: fingerprint) {
            case .accept:
                storedPeer = peer
                return true
            case .reject(let error):
                storedFailure = error
                return false
            }
        }
    }

    private func reject(_ error: SonyTLSChannelError) -> Bool {
        lock.withLock { storedFailure = error }
        return false
    }
}
