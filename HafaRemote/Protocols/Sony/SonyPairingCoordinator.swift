import Foundation
import Security

typealias SonyPairingCodeProvider = @MainActor @Sendable () async throws -> String

protocol SonyPairingCoordinating: TVDriver {
    func connect(
        to target: TVConnectionTarget,
        requestPairingCode: @escaping SonyPairingCodeProvider
    ) async throws -> ConnectedTV
    func forget(reportedDeviceID: String) async throws
    /// Deletes a saved Sony fingerprint without requiring control-channel teardown.
    func removeCredential(reportedDeviceID: String) async throws
}

extension SonyPairingCoordinating {
    /// Refuses to treat a potentially destructive legacy forget as credential-only.
    func removeCredential(reportedDeviceID: String) async throws {
        throw RemoteCredentialRemovalError.unsupported
    }
}

actor SonyPairingCoordinator: SonyPairingCoordinating {
    private static let pairingPort: UInt16 = 6467
    private static let controlPort: UInt16 = 6466
    private static let pairingExchangeTimeout: Duration = .seconds(90)
    private static let remoteHandshakeTimeout: Duration = .seconds(10)
    private static let maximumRemoteHandshakeMessages = 128

    private let identityStore: SonyClientIdentityStore
    private let credentialStore: any SonyPairingCredentialStoring
    private let pairingChannel: any SonyTLSChanneling
    private let controlChannel: any SonyTLSChanneling
    private let writeSerializer = SonyWriteSerializer()

    private var readTask: Task<Void, Never>?
    private var sessionGeneration = UUID()

    init(
        identityStore: SonyClientIdentityStore = SonyClientIdentityStore(),
        credentialStore: any SonyPairingCredentialStoring = KeychainSonyPairingCredentialStore(),
        pairingChannel: any SonyTLSChanneling = SonyTLSChannel(),
        controlChannel: any SonyTLSChanneling = SonyTLSChannel()
    ) {
        self.identityStore = identityStore
        self.credentialStore = credentialStore
        self.pairingChannel = pairingChannel
        self.controlChannel = controlChannel
    }

    func connect(
        to target: TVConnectionTarget,
        requestPairingCode: @escaping SonyPairingCodeProvider
    ) async throws -> ConnectedTV {
        guard target.brand == .sony,
            target.controlPort == nil || target.controlPort == Self.controlPort
        else {
            throw SonyPairingCoordinatorError.unsupportedDevice
        }

        await disconnect()
        let identity = SonyClientIdentityReference(try identityStore.identity())

        do {
            let credential: SonyPairingCredential
            if let savedCredential = try await savedCredential(for: target) {
                credential = savedCredential
            } else {
                credential = try await pair(
                    address: target.address,
                    identity: identity,
                    requestPairingCode: requestPairingCode
                )
            }
            return try await openRemote(
                address: target.address,
                identity: identity,
                credential: credential
            )
        } catch {
            await disconnect()
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    func send(_ command: RemoteCommand) async throws {
        let message = try SonyRemoteProtocolCodec.command(command)
        try await writeSerializer.perform { [controlChannel] in
            try await controlChannel.send(message)
        }
    }

    func sendText(_ input: RemoteTextInput) async throws {
        throw TVDriverError.unsupportedTextInput
    }

    func forget(reportedDeviceID: String) async throws {
        await disconnect()
        try await removeCredential(reportedDeviceID: reportedDeviceID)
    }

    /// Deletes the saved Sony certificate fingerprint without closing another active session.
    func removeCredential(reportedDeviceID: String) async throws {
        try Task.checkCancellation()
        try await credentialStore.remove(reportedDeviceID: reportedDeviceID)
    }

    func disconnect() async {
        sessionGeneration = UUID()
        readTask?.cancel()
        readTask = nil
        await pairingChannel.disconnect()
        await controlChannel.disconnect()
    }

    private func savedCredential(for target: TVConnectionTarget) async throws -> SonyPairingCredential? {
        guard let candidate = try? SonyPairingCredential(reportedDeviceID: target.reportedDeviceID)
        else {
            return nil
        }
        return try await SonyRecoverableCredentialLookup.credential(
            in: credentialStore,
            fingerprint: candidate.certificateSHA256
        )
    }

    private func pair(
        address: PrivateIPv4Address,
        identity: SonyClientIdentityReference,
        requestPairingCode: @escaping SonyPairingCodeProvider
    ) async throws -> SonyPairingCredential {
        let peer = try await pairingChannel.connect(
            address: address,
            port: Self.pairingPort,
            identity: identity,
            trustMode: .selectedPairingCandidate
        )

        if let saved = try await SonyRecoverableCredentialLookup.credential(
            in: credentialStore,
            fingerprint: peer.certificateSHA256
        ) {
            await pairingChannel.disconnect()
            return saved
        }

        let credential = try await SonyPairingExchangeDeadline.run(
            timeout: Self.pairingExchangeTimeout
        ) { [pairingChannel] in
            try await Self.completePairingExchange(
                on: pairingChannel,
                identity: identity,
                peer: peer,
                requestPairingCode: requestPairingCode
            )
        }
        try await credentialStore.save(credential)
        await pairingChannel.disconnect()
        return credential
    }

    private static func completePairingExchange(
        on pairingChannel: any SonyTLSChanneling,
        identity: SonyClientIdentityReference,
        peer: SonyTLSPeer,
        requestPairingCode: @escaping SonyPairingCodeProvider
    ) async throws -> SonyPairingCredential {
        try await pairingChannel.send(SonyPairingProtocolCodec.request(clientName: "Hafa Remote"))
        guard try await pairingMessage(on: pairingChannel) == .requestAcknowledged else {
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }
        try await pairingChannel.send(SonyPairingProtocolCodec.options())
        guard try await pairingMessage(on: pairingChannel) == .options else {
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }
        try await pairingChannel.send(SonyPairingProtocolCodec.configuration())
        guard try await pairingMessage(on: pairingChannel) == .configurationAcknowledged else {
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }

        let code = try await requestPairingCode()
        let clientCertificate = try certificate(from: identity.value)
        guard let serverCertificate = SecCertificateCreateWithData(nil, peer.certificateDER as CFData)
        else {
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }
        let secret: Data
        do {
            secret = try SonyPairingSecret.make(
                pairingCode: code,
                clientCertificate: clientCertificate,
                serverCertificate: serverCertificate
            )
        } catch SonyClientIdentityError.invalidPairingCode {
            throw SonyPairingCoordinatorError.invalidPairingCode
        } catch SonyClientIdentityError.pairingCodeMismatch {
            throw SonyPairingCoordinatorError.invalidPairingCode
        }

        try await pairingChannel.send(try SonyPairingProtocolCodec.secret(secret))
        guard try await pairingMessage(on: pairingChannel) == .secretAcknowledged else {
            throw SonyPairingCoordinatorError.pairingRejected
        }

        return try SonyPairingCredential(
            certificateSHA256: peer.certificateSHA256
        )
    }

    private static func pairingMessage(on pairingChannel: any SonyTLSChanneling) async throws
        -> SonyPairingMessage
    {
        do {
            return try SonyPairingProtocolCodec.parse(await pairingChannel.receive())
        } catch let error as SonyProtocolCodecError {
            if case .pairingRejected = error {
                throw SonyPairingCoordinatorError.pairingRejected
            }
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }
    }

    private func openRemote(
        address: PrivateIPv4Address,
        identity: SonyClientIdentityReference,
        credential: SonyPairingCredential
    ) async throws -> ConnectedTV {
        let peer = try await controlChannel.connect(
            address: address,
            port: Self.controlPort,
            identity: identity,
            trustMode: .reconnect(expectedCertificateSHA256: credential.certificateSHA256)
        )
        guard peer.certificateSHA256 == credential.certificateSHA256 else {
            throw SonyPairingCoordinatorError.certificateChanged
        }

        let device = try await SonyRemoteHandshake.run(
            on: controlChannel,
            fallbackModelName: peer.displayName,
            timeout: Self.remoteHandshakeTimeout,
            maximumMessages: Self.maximumRemoteHandshakeMessages
        )

        let generation = UUID()
        sessionGeneration = generation
        readTask = Task { [weak self] in
            await self?.readRemoteEvents(generation: generation)
        }
        return ConnectedTV(
            brand: .sony,
            reportedDeviceID: credential.reportedDeviceID,
            address: address,
            controlPort: Self.controlPort,
            displayName: peer.displayName,
            modelName: device.model,
            firmwareVersion: device.softwareVersion.isEmpty ? nil : device.softwareVersion
        )
    }

    private func readRemoteEvents(generation: UUID) async {
        do {
            while sessionGeneration == generation, !Task.isCancelled {
                switch try SonyRemoteProtocolCodec.parse(await controlChannel.receive()) {
                case .ping(let value):
                    try await writeSerializer.perform { [controlChannel] in
                        try await controlChannel.send(SonyRemoteProtocolCodec.pingResponse(value))
                    }
                case .setActive:
                    try await writeSerializer.perform { [controlChannel] in
                        try await controlChannel.send(SonyRemoteProtocolCodec.activeResponse())
                    }
                case .configured:
                    try await writeSerializer.perform { [controlChannel] in
                        try await controlChannel.send(SonyRemoteProtocolCodec.configurationResponse())
                    }
                case .powerState, .other:
                    continue
                }
            }
        } catch {
            // A later command or lifecycle transition owns user-visible recovery.
        }
    }

    private static func certificate(from identity: SecIdentity) throws -> SecCertificate {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
            let certificate
        else {
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }
        return certificate
    }
}

struct SonyRemoteDevice: Sendable {
    let model: String
    let softwareVersion: String
}

enum SonyPairingExchangeDeadline {
    static func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await SonyTLSConnectionDeadline.run(
                timeout: timeout,
                operation: operation
            )
        } catch SonyTLSChannelError.timedOut {
            throw SonyPairingCoordinatorError.pairingTimedOut
        }
    }
}

enum SonyRemoteHandshake {
    private static let keyFeature: UInt64 = 2

    static func run(
        on controlChannel: any SonyTLSChanneling,
        fallbackModelName: String,
        timeout: Duration,
        maximumMessages: Int
    ) async throws -> SonyRemoteDevice {
        do {
            return try await SonyTLSConnectionDeadline.run(timeout: timeout) {
                try await complete(
                    on: controlChannel,
                    fallbackModelName: fallbackModelName,
                    maximumMessages: maximumMessages
                )
            }
        } catch SonyTLSChannelError.timedOut {
            throw SonyPairingCoordinatorError.remoteHandshakeTimedOut
        }
    }

    private static func complete(
        on controlChannel: any SonyTLSChanneling,
        fallbackModelName: String,
        maximumMessages: Int
    ) async throws -> SonyRemoteDevice {
        var device: SonyRemoteDevice?
        for _ in 0..<maximumMessages {
            switch try SonyRemoteProtocolCodec.parse(await controlChannel.receive()) {
            case .configured(let vendor, let model, let softwareVersion, let supportedFeatures):
                guard vendor.localizedCaseInsensitiveContains("sony"),
                    supportedFeatures & keyFeature == keyFeature
                else {
                    throw SonyPairingCoordinatorError.unsupportedDevice
                }
                device = SonyRemoteDevice(
                    model: model.isEmpty ? fallbackModelName : model,
                    softwareVersion: softwareVersion
                )
                try await controlChannel.send(SonyRemoteProtocolCodec.configurationResponse())
            case .setActive:
                try await controlChannel.send(SonyRemoteProtocolCodec.activeResponse())
            case .ping(let value):
                try await controlChannel.send(SonyRemoteProtocolCodec.pingResponse(value))
            case .powerState:
                guard let device else {
                    throw SonyPairingCoordinatorError.invalidRemoteResponse
                }
                return device
            case .other:
                continue
            }
        }
        throw SonyPairingCoordinatorError.remoteHandshakeTimedOut
    }
}

actor SonyWriteSerializer {
    private var isExecuting = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []

    func perform(_ operation: @Sendable () async throws -> Void) async throws {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isExecuting {
            isExecuting = true
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        guard acquired else { throw CancellationError() }
    }

    private func release() {
        if waiters.isEmpty {
            isExecuting = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

enum SonyPairingCoordinatorError: LocalizedError, Equatable, Sendable {
    case unsupportedDevice
    case invalidPairingResponse
    case invalidPairingCode
    case pairingRejected
    case pairingTimedOut
    case invalidRemoteResponse
    case remoteHandshakeTimedOut
    case certificateChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            "This device did not identify itself as a compatible Sony Google TV."
        case .invalidPairingResponse, .invalidRemoteResponse:
            "The Sony TV returned an unexpected response. Try again."
        case .remoteHandshakeTimedOut:
            "The Sony TV did not finish connecting. Make sure it is awake, then try again."
        case .invalidPairingCode:
            "That pairing code did not match the code on the Sony TV."
        case .pairingRejected:
            "The Sony TV did not approve Hafa Remote. Try pairing again."
        case .pairingTimedOut:
            "Sony TV pairing took too long. Try again and enter the code shown on the TV."
        case .certificateChanged:
            "This Sony TV's security identity changed. Remove its saved pairing before reconnecting."
        }
    }
}
