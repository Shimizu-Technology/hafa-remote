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
    nonisolated func cancellationInvalidatesConnection() async -> Bool { true }

    private static let pairingPort: UInt16 = 6467
    private static let controlPort: UInt16 = 6466
    private static let pairingExchangeTimeout: Duration = .seconds(90)
    private static let remoteHandshakeTimeout: Duration = .seconds(10)
    private static let maximumRemoteHandshakeMessages = 128

    private let identityProvider: @Sendable () throws -> SonyClientIdentityReference
    private let credentialStore: any SonyPairingCredentialStoring
    private let pairingChannel: any SonyTLSChanneling
    private let controlChannel: any SonyTLSChanneling
    private let writeSerializer = SonyWriteSerializer()
    private let teardownSerializer = SonyWriteSerializer()
    private let keyboardPreference: @MainActor @Sendable (String) -> Bool

    private let observationBroadcaster = TVSessionObservationBroadcaster()
    private var activeTV: ConnectedTV?
    private var negotiatedFeatures: UInt64 = 0
    private var reportedFeatures: UInt64 = 0
    private var keyboardEnabled = true
    private var imeFocus = SonyIMEFocus()
    private var requestedFeatures: UInt64 {
        SonyRemoteProtocolCodec.requestedFeatures & (keyboardEnabled ? UInt64.max : ~UInt64(4))
    }
    private var readTask: Task<Void, Never>?
    private var sessionGeneration = UUID()
    private var channelOwnership = SonyTLSChannelOwnership()
    private var isRemoteSessionAlive = false

    init(
        identityStore: SonyClientIdentityStore = SonyClientIdentityStore(),
        identityProvider: (@Sendable () throws -> SonyClientIdentityReference)? = nil,
        credentialStore: any SonyPairingCredentialStoring = KeychainSonyPairingCredentialStore(),
        pairingChannel: any SonyTLSChanneling = SonyTLSChannel(),
        controlChannel: any SonyTLSChanneling = SonyTLSChannel(),
        keyboardPreference: @escaping @MainActor @Sendable (String) -> Bool = {
            TVConveniencePreferences.shared.keyboardEnabled(for: $0)
        }
    ) {
        self.identityProvider =
            identityProvider ?? {
                SonyClientIdentityReference(try identityStore.identity())
            }
        self.credentialStore = credentialStore
        self.pairingChannel = pairingChannel
        self.controlChannel = controlChannel
        self.keyboardPreference = keyboardPreference
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

        return try await performConnectionAttempt { [weak self] generation in
            guard let self else { throw CancellationError() }
            return try await self.connectWithinAttempt(
                to: target, generation: generation, requestPairingCode: requestPairingCode)
        }
    }

    /// The timeout owner can stop waiting before a cancelled TLS callback unwinds.
    /// Cleanup may close only the generation that began this attempt.
    private func performConnectionAttempt(
        _ operation: @escaping @Sendable (UUID) async throws -> ConnectedTV
    ) async throws -> ConnectedTV {
        try Task.checkCancellation()
        let generation = UUID()
        await closeSession(generation: generation)
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        do {
            let television = try await operation(generation)
            try Task.checkCancellation()
            guard sessionGeneration == generation else { throw CancellationError() }
            return television
        } catch {
            if sessionGeneration == generation { await closeSession(generation: UUID()) }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func connectWithinAttempt(
        to target: TVConnectionTarget,
        generation: UUID,
        requestPairingCode: @escaping SonyPairingCodeProvider
    ) async throws -> ConnectedTV {
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        let ownership = channelOwnership
        let identity = try identityProvider()
        let credential: SonyPairingCredential
        let saved = try await savedCredential(for: target)
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        if let saved {
            credential = saved
        } else {
            guard target.expectedSavedDeviceID == nil else {
                throw SonyPairingCoordinatorError.pairingRejected
            }
            credential = try await pair(
                address: target.address, identity: identity, generation: generation, ownership: ownership,
                requestPairingCode: requestPairingCode)
        }
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        return try await openRemote(
            address: target.address, identity: identity, credential: credential, generation: generation,
            ownership: ownership)
    }

    func send(_ command: RemoteCommand) async throws {
        guard isRemoteSessionAlive else { throw SonyTLSChannelError.connectionClosed }
        guard activeTV?.capabilities.contains(command.requiredCapability) == true else {
            throw TVDriverError.unsupportedCommand
        }
        let generation = sessionGeneration
        try await writeSerializer.perform { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.writeCommand(command, generation: generation)
        }
    }

    private func writeCommand(_ command: RemoteCommand, generation: UUID) async throws {
        try requireAttempt(generation)
        guard isRemoteSessionAlive else { throw SonyTLSChannelError.connectionClosed }
        guard activeTV?.capabilities.contains(command.requiredCapability) == true else {
            throw TVDriverError.unsupportedCommand
        }
        let invalidatesFocus =
            [.navigation, .powerOff, .powerOn, .sourceMenu, .channels, .guide, .numberPad].contains(
                command.requiredCapability)
        if invalidatesFocus { imeFocus.clear() }
        defer {
            if invalidatesFocus, sessionGeneration == generation { imeFocus.clear() }
        }
        let ownership = channelOwnership
        let message = try SonyRemoteProtocolCodec.command(command)
        try await controlChannel.send(message, ownership: ownership)
        try requireAttempt(generation)
    }

    func sendText(_ input: RemoteTextInput) async throws {
        guard keyboardEnabled, negotiatedFeatures & 4 != 0 else { throw TVDriverError.unsupportedTextInput }
        let generation = sessionGeneration
        try await writeSerializer.perform { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.writeText(input, generation: generation)
        }
    }

    private func writeText(_ input: RemoteTextInput, generation: UUID) async throws {
        try Task.checkCancellation()
        guard sessionGeneration == generation, isRemoteSessionAlive, keyboardEnabled,
            negotiatedFeatures & 4 != 0,
            activeTV?.powerState != .standby
        else { throw TVConvenienceError.textFieldNotFocused }
        let counters = try imeFocus.snapshot()
        let message = try SonyConvenienceCodec.text(
            input, imeCounter: counters.ime, fieldCounter: counters.field)
        imeFocus.clear()
        let ownership = channelOwnership
        try await controlChannel.send(message, ownership: ownership)
        try requireAttempt(generation)
    }

    func convenience(_ request: TVConvenienceRequest) async throws -> TVConvenienceResponse {
        guard isRemoteSessionAlive else { throw SonyTLSChannelError.connectionClosed }
        switch request {
        case .apps:
            guard negotiatedFeatures & 512 != 0 else { throw TVConvenienceError.unavailable }
            return .apps(TVAppShortcut.sonyConfiguredLinks)
        case .launch(let app):
            guard negotiatedFeatures & 512 != 0 else { throw TVConvenienceError.unavailable }
            let message = try SonyConvenienceCodec.launch(app)
            let generation = sessionGeneration
            try await writeSerializer.perform { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.writeConvenience(message, generation: generation, invalidatesFocus: true)
            }
            return .sent
        case .setKeyboardEnabled(let enabled):
            let generation = sessionGeneration
            try await writeSerializer.perform { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.configureKeyboard(enabled, generation: generation)
            }
            return .sent
        default: throw TVConvenienceError.unavailable
        }
    }

    private func configureKeyboard(_ enabled: Bool, generation: UUID) async throws {
        try Task.checkCancellation()
        guard sessionGeneration == generation, isRemoteSessionAlive, let television = activeTV else {
            throw CancellationError()
        }
        let serverFeatures = reportedFeatures
        let proposedFeatures = serverFeatures & Self.requestedFeatures(keyboardEnabled: enabled)
        let message = SonyRemoteProtocolCodec.configurationResponse(negotiatedFeatures: proposedFeatures)
        try await writeConvenience(message, generation: generation)
        try Task.checkCancellation()
        guard sessionGeneration == generation, activeTV?.stableDeviceKey == television.stableDeviceKey,
            reportedFeatures == serverFeatures, isRemoteSessionAlive
        else { throw CancellationError() }
        // Only a successfully written, still-owned transaction changes local negotiation.
        keyboardEnabled = enabled
        negotiatedFeatures = proposedFeatures
        imeFocus.clear()
        await publishObservation(powerState: television.powerState, generation: generation)
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
    }

    private func writeConvenience(
        _ message: Data, generation: UUID, invalidatesFocus: Bool = false
    ) async throws {
        try Task.checkCancellation()
        guard sessionGeneration == generation, isRemoteSessionAlive else { throw CancellationError() }
        let ownership = channelOwnership
        if invalidatesFocus { imeFocus.clear() }
        defer {
            if invalidatesFocus, sessionGeneration == generation { imeFocus.clear() }
        }
        do {
            try await controlChannel.send(message, ownership: ownership)
            try Task.checkCancellation()
            guard sessionGeneration == generation else { throw CancellationError() }
        } catch {
            if sessionGeneration == generation { isRemoteSessionAlive = false }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw SonyTLSChannelError.unavailable
        }
    }

    private static func requestedFeatures(keyboardEnabled: Bool) -> UInt64 {
        SonyRemoteProtocolCodec.requestedFeatures & (keyboardEnabled ? UInt64.max : ~UInt64(4))
    }

    #if DEBUG
        /// Installs only synthetic injected-channel sessions, without pairing/network/keychain access.
        func installSyntheticSessionForTesting(_ television: ConnectedTV, reportedFeatures: UInt64)
            async throws
        {
            _ = try await attemptSyntheticConnectionForTesting(reportedFeatures: reportedFeatures) {
                television
            }
        }
        /// Injects a held transport callback into the production attempt/cleanup owner.
        func attemptSyntheticConnectionForTesting(
            reportedFeatures: UInt64,
            operation: @escaping @Sendable () async throws -> ConnectedTV
        ) async throws -> ConnectedTV {
            try await performConnectionAttempt { [weak self] generation in
                let television = try await operation()
                guard let self else { throw CancellationError() }
                try await self.activateSyntheticSession(
                    television, reportedFeatures: reportedFeatures, generation: generation)
                return television
            }
        }
        private func activateSyntheticSession(
            _ television: ConnectedTV, reportedFeatures: UInt64, generation: UUID
        ) async throws {
            try Task.checkCancellation()
            guard sessionGeneration == generation, television.brand == .sony else {
                throw CancellationError()
            }
            let enabled = await keyboardPreference(television.stableDeviceKey)
            try Task.checkCancellation()
            guard sessionGeneration == generation else { throw CancellationError() }
            keyboardEnabled = enabled
            self.reportedFeatures = reportedFeatures
            negotiatedFeatures = reportedFeatures & Self.requestedFeatures(keyboardEnabled: enabled)
            activeTV = television
            isRemoteSessionAlive = true
        }
        func focusSyntheticFieldForTesting(imeCounter: UInt64? = 1) {
            imeFocus.focus(fieldCounter: 1)
            if let imeCounter { imeFocus.counters(ime: imeCounter, field: 1) }
        }
        func syntheticKeyboardStateForTesting() -> (enabled: Bool, features: UInt64, hasFocus: Bool) {
            (keyboardEnabled, negotiatedFeatures, (try? imeFocus.snapshot()) != nil)
        }
    #endif

    func checkConnection() async throws {
        guard isRemoteSessionAlive else {
            throw SonyTLSChannelError.connectionClosed
        }
        let generation = sessionGeneration
        let ownership = channelOwnership
        try await controlChannel.checkConnection(ownership: ownership)
        try requireAttempt(generation)
    }

    func forget(reportedDeviceID: String) async throws {
        try Task.checkCancellation()
        await disconnect()
        try await removeCredential(reportedDeviceID: reportedDeviceID)
    }

    /// Deletes the saved Sony certificate fingerprint without closing another active session.
    func removeCredential(reportedDeviceID: String) async throws {
        try Task.checkCancellation()
        try await credentialStore.remove(reportedDeviceID: reportedDeviceID)
    }

    func sessionObservation() async throws -> TVSessionObservation? {
        await observationBroadcaster.snapshot()
    }

    func observations() async -> AsyncStream<TVSessionObservation> {
        await observationBroadcaster.stream()
    }

    func disconnect() async {
        await closeSession(generation: UUID())
    }

    private func closeSession(generation: UUID) async {
        let previousOwnership = channelOwnership
        previousOwnership.invalidate()
        channelOwnership = SonyTLSChannelOwnership()
        sessionGeneration = generation
        isRemoteSessionAlive = false
        readTask?.cancel()
        readTask = nil
        activeTV = nil
        negotiatedFeatures = 0
        reportedFeatures = 0
        keyboardEnabled = true
        imeFocus.clear()
        let teardown = Task { [weak self, teardownSerializer] in
            guard let self else { return }
            try? await teardownSerializer.perform {
                await self.closeChannels(generation: generation, ownership: previousOwnership)
            }
        }
        // Cleanup must finish even when its connection work was cancelled. A new
        // attempt awaits this teardown FIFO before opening replacement channels.
        await teardown.value
    }

    private func closeChannels(generation: UUID, ownership: SonyTLSChannelOwnership) async {
        guard sessionGeneration == generation else { return }
        await observationBroadcaster.reset()
        guard sessionGeneration == generation else { return }
        await pairingChannel.disconnect(ownership: ownership)
        guard sessionGeneration == generation else { return }
        await controlChannel.disconnect(ownership: ownership)
    }

    private func requireAttempt(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        try channelOwnership.requireCurrent()
    }

    private func savedCredential(for target: TVConnectionTarget) async throws -> SonyPairingCredential? {
        try await SonySavedTargetCredentialLookup.credential(for: target, in: credentialStore)
    }

    private func pair(
        address: PrivateIPv4Address,
        identity: SonyClientIdentityReference,
        generation: UUID,
        ownership: SonyTLSChannelOwnership,
        requestPairingCode: @escaping SonyPairingCodeProvider
    ) async throws -> SonyPairingCredential {
        try requireAttempt(generation)
        let peer = try await pairingChannel.connect(
            address: address,
            port: Self.pairingPort,
            identity: identity,
            trustMode: .selectedPairingCandidate,
            ownership: ownership
        )
        try requireAttempt(generation)

        let saved = try await SonyRecoverableCredentialLookup.credential(
            in: credentialStore,
            fingerprint: peer.certificateSHA256
        )
        try requireAttempt(generation)
        if let saved {
            await pairingChannel.disconnect(ownership: ownership)
            try requireAttempt(generation)
            return saved
        }

        let validateAttempt: @Sendable () async throws -> Void = { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.requireAttempt(generation)
        }
        let ownedPairingCode: SonyPairingCodeProvider = {
            try ownership.requireCurrent()
            let code = try await requestPairingCode()
            try ownership.requireCurrent()
            return code
        }
        let credential = try await SonyPairingExchangeDeadline.run(
            timeout: Self.pairingExchangeTimeout
        ) { [pairingChannel] in
            try await Self.completePairingExchange(
                on: pairingChannel,
                identity: identity,
                peer: peer,
                ownership: ownership,
                validateAttempt: validateAttempt,
                requestPairingCode: ownedPairingCode
            )
        }
        try requireAttempt(generation)
        try await credentialStore.save(credential)
        try requireAttempt(generation)
        await pairingChannel.disconnect(ownership: ownership)
        try requireAttempt(generation)
        return credential
    }

    private static func completePairingExchange(
        on pairingChannel: any SonyTLSChanneling,
        identity: SonyClientIdentityReference,
        peer: SonyTLSPeer,
        ownership: SonyTLSChannelOwnership,
        validateAttempt: @escaping @Sendable () async throws -> Void,
        requestPairingCode: @escaping SonyPairingCodeProvider
    ) async throws -> SonyPairingCredential {
        try await validateAttempt()
        try await pairingChannel.send(
            SonyPairingProtocolCodec.request(clientName: "Hafa Remote"), ownership: ownership)
        try await validateAttempt()
        guard
            try await pairingMessage(
                on: pairingChannel, ownership: ownership, validateAttempt: validateAttempt)
                == .requestAcknowledged
        else {
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }
        try await pairingChannel.send(SonyPairingProtocolCodec.options(), ownership: ownership)
        try await validateAttempt()
        guard
            try await pairingMessage(
                on: pairingChannel, ownership: ownership, validateAttempt: validateAttempt)
                == .options
        else {
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }
        try await pairingChannel.send(SonyPairingProtocolCodec.configuration(), ownership: ownership)
        try await validateAttempt()
        guard
            try await pairingMessage(
                on: pairingChannel, ownership: ownership, validateAttempt: validateAttempt)
                == .configurationAcknowledged
        else {
            throw SonyPairingCoordinatorError.invalidPairingResponse
        }

        let code = try await requestPairingCode()
        try await validateAttempt()
        let clientCertificate = try identity.certificate()
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

        try await validateAttempt()
        try await pairingChannel.send(try SonyPairingProtocolCodec.secret(secret), ownership: ownership)
        try await validateAttempt()
        guard
            try await pairingMessage(
                on: pairingChannel, ownership: ownership, validateAttempt: validateAttempt)
                == .secretAcknowledged
        else {
            throw SonyPairingCoordinatorError.pairingRejected
        }

        return try SonyPairingCredential(
            certificateSHA256: peer.certificateSHA256
        )
    }

    private static func pairingMessage(
        on pairingChannel: any SonyTLSChanneling, ownership: SonyTLSChannelOwnership,
        validateAttempt: @Sendable () async throws -> Void
    ) async throws
        -> SonyPairingMessage
    {
        do {
            try await validateAttempt()
            let message = try await pairingChannel.receive(ownership: ownership)
            try await validateAttempt()
            return try SonyPairingProtocolCodec.parse(message)
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
        credential: SonyPairingCredential,
        generation connectionGeneration: UUID,
        ownership: SonyTLSChannelOwnership
    ) async throws -> ConnectedTV {
        try requireAttempt(connectionGeneration)
        let peer = try await controlChannel.connect(
            address: address,
            port: Self.controlPort,
            identity: identity,
            trustMode: .reconnect(expectedCertificateSHA256: credential.certificateSHA256),
            ownership: ownership
        )
        try requireAttempt(connectionGeneration)
        guard peer.certificateSHA256 == credential.certificateSHA256 else {
            throw SonyPairingCoordinatorError.certificateChanged
        }

        let preferredKeyboard = await keyboardPreference("sony:\(credential.reportedDeviceID)")
        try Task.checkCancellation()
        guard sessionGeneration == connectionGeneration else { throw CancellationError() }
        let device = try await SonyRemoteHandshake.run(
            on: controlChannel,
            fallbackModelName: "Sony Google TV",
            timeout: Self.remoteHandshakeTimeout,
            maximumMessages: Self.maximumRemoteHandshakeMessages,
            requestedFeatures: Self.requestedFeatures(keyboardEnabled: preferredKeyboard),
            ownership: ownership
        )

        try Task.checkCancellation()
        guard sessionGeneration == connectionGeneration else { throw CancellationError() }
        let television = ConnectedTV(
            brand: .sony,
            reportedDeviceID: credential.reportedDeviceID,
            address: address,
            controlPort: Self.controlPort,
            displayName: peer.displayName,
            modelName: device.model,
            firmwareVersion: device.softwareVersion.isEmpty ? nil : device.softwareVersion,
            powerState: device.powerState,
            capabilityEvidence: TVCapabilityEvidence(
                implemented: TVCapability.implemented(for: .sony),
                protocolReported: device.capabilities
            )
        )
        activeTV = television
        keyboardEnabled = preferredKeyboard
        negotiatedFeatures = device.negotiatedFeatures
        reportedFeatures = device.reportedFeatures
        await observationBroadcaster.publish(
            TVSessionObservation(
                stableDeviceKey: television.stableDeviceKey,
                powerState: device.powerState,
                protocolReportedCapabilities: device.capabilities
            ))
        try Task.checkCancellation()
        guard sessionGeneration == connectionGeneration else { throw CancellationError() }
        let generation = connectionGeneration
        isRemoteSessionAlive = true
        readTask = Task { [weak self] in
            await self?.readRemoteEvents(generation: generation, ownership: ownership)
        }
        return television
    }

    private func readRemoteEvents(generation: UUID, ownership: SonyTLSChannelOwnership) async {
        do {
            var consecutiveProtocolFailures = 0
            while sessionGeneration == generation, !Task.isCancelled {
                let message = try await controlChannel.receive(ownership: ownership)
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                let event: SonyRemoteEvent
                do {
                    event = try SonyRemoteProtocolCodec.parse(message)
                    consecutiveProtocolFailures = 0
                } catch is SonyProtocolCodecError {
                    consecutiveProtocolFailures += 1
                    guard consecutiveProtocolFailures >= 3 else { continue }
                    throw SonyTLSChannelError.unavailable
                }
                switch event {
                case .ping(let value):
                    try await writeSerializer.perform { [controlChannel] in
                        try await controlChannel.send(
                            SonyRemoteProtocolCodec.pingResponse(value), ownership: ownership)
                    }
                case .setActive:
                    let features = negotiatedFeatures
                    try await writeSerializer.perform { [controlChannel] in
                        try await controlChannel.send(
                            SonyRemoteProtocolCodec.activeResponse(negotiatedFeatures: features),
                            ownership: ownership)
                    }
                case .configured(let vendor, _, _, let reportedFeatures):
                    guard vendor.localizedCaseInsensitiveContains("sony"), reportedFeatures & 2 == 2 else {
                        throw SonyPairingCoordinatorError.unsupportedDevice
                    }
                    self.reportedFeatures = reportedFeatures
                    negotiatedFeatures = reportedFeatures & requestedFeatures
                    imeFocus.clear()
                    let features = negotiatedFeatures
                    try await writeSerializer.perform { [controlChannel] in
                        try await controlChannel.send(
                            SonyRemoteProtocolCodec.configurationResponse(negotiatedFeatures: features),
                            ownership: ownership)
                    }
                    await publishObservation(
                        powerState: activeTV?.powerState ?? .unknown, generation: generation)
                case .imeFocus(let counter):
                    imeFocus.focus(fieldCounter: keyboardEnabled ? counter : nil)
                case .imeCounters(let ime, let field):
                    if keyboardEnabled { imeFocus.counters(ime: ime, field: field) }
                case .powerState(let isOn):
                    if !isOn { imeFocus.clear() }
                    await publishObservation(powerState: isOn ? .on : .standby, generation: generation)
                case .other:
                    continue
                }
            }
        } catch {
            if sessionGeneration == generation {
                isRemoteSessionAlive = false
            }
        }
    }

    private func publishObservation(powerState: TVPowerState, generation: UUID) async {
        guard sessionGeneration == generation, let television = activeTV else { return }
        let observation = TVSessionObservation(
            stableDeviceKey: television.stableDeviceKey,
            powerState: powerState,
            protocolReportedCapabilities: SonyRemoteDevice.capabilities(for: negotiatedFeatures)
        )
        activeTV = television.applying(observation)
        await observationBroadcaster.publish(observation)
    }

}

enum SonySavedTargetCredentialLookup {
    static func credential(
        for target: TVConnectionTarget,
        in store: any SonyPairingCredentialStoring
    ) async throws -> SonyPairingCredential? {
        // Service-name hashes and certificate fingerprints have the same shape.
        // Only the authenticated identity of a remembered TV may choose a pin.
        guard target.brand == .sony,
            let expectedIdentity = target.expectedSavedDeviceID,
            let candidate = try? SonyPairingCredential(reportedDeviceID: expectedIdentity)
        else { return nil }
        return try await SonyRecoverableCredentialLookup.credential(
            in: store,
            fingerprint: candidate.certificateSHA256
        )
    }
}

struct SonyRemoteDevice: Sendable {
    let model: String
    let softwareVersion: String
    let negotiatedFeatures: UInt64
    let powerState: TVPowerState
    var reportedFeatures: UInt64 = 0

    var capabilities: Set<TVCapability> { Self.capabilities(for: negotiatedFeatures) }

    static func capabilities(for features: UInt64) -> Set<TVCapability> {
        var capabilities: Set<TVCapability> = []
        if features & 2 != 0 {
            capabilities.formUnion([.navigation, .playback, .sourceMenu, .channels, .guide, .numberPad])
        }
        if features & 4 != 0 { capabilities.insert(.textInput) }
        if features & 512 != 0 { capabilities.insert(.favoriteApps) }
        if features & 64 != 0 { capabilities.formUnion([.volume, .mute]) }
        if features & 32 != 0 { capabilities.formUnion([.powerOff, .powerOn]) }
        return capabilities
    }
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
        maximumMessages: Int,
        requestedFeatures: UInt64 = SonyRemoteProtocolCodec.requestedFeatures,
        ownership: SonyTLSChannelOwnership? = nil
    ) async throws -> SonyRemoteDevice {
        do {
            return try await SonyTLSConnectionDeadline.run(timeout: timeout) {
                try await complete(
                    on: controlChannel,
                    fallbackModelName: fallbackModelName,
                    maximumMessages: maximumMessages,
                    requestedFeatures: requestedFeatures,
                    ownership: ownership
                )
            }
        } catch SonyTLSChannelError.timedOut {
            throw SonyPairingCoordinatorError.remoteHandshakeTimedOut
        }
    }

    private static func complete(
        on controlChannel: any SonyTLSChanneling,
        fallbackModelName: String,
        maximumMessages: Int,
        requestedFeatures: UInt64,
        ownership: SonyTLSChannelOwnership?
    ) async throws -> SonyRemoteDevice {
        var device: SonyRemoteDevice?
        for _ in 0..<maximumMessages {
            try Task.checkCancellation()
            try ownership?.requireCurrent()
            let message: Data
            if let ownership {
                message = try await controlChannel.receive(ownership: ownership)
            } else {
                message = try await controlChannel.receive()
            }
            try Task.checkCancellation()
            try ownership?.requireCurrent()
            switch try SonyRemoteProtocolCodec.parse(message) {
            case .configured(let vendor, let model, let softwareVersion, let supportedFeatures):
                guard vendor.localizedCaseInsensitiveContains("sony"),
                    supportedFeatures & keyFeature == keyFeature
                else {
                    throw SonyPairingCoordinatorError.unsupportedDevice
                }
                device = SonyRemoteDevice(
                    model: model.isEmpty ? fallbackModelName : model,
                    softwareVersion: softwareVersion,
                    negotiatedFeatures: supportedFeatures & requestedFeatures,
                    powerState: .unknown,
                    reportedFeatures: supportedFeatures
                )
                try await send(
                    SonyRemoteProtocolCodec.configurationResponse(
                        negotiatedFeatures: supportedFeatures & requestedFeatures
                    ), on: controlChannel, ownership: ownership)
            case .setActive:
                try await send(
                    SonyRemoteProtocolCodec.activeResponse(
                        negotiatedFeatures: device?.negotiatedFeatures ?? 0
                    ), on: controlChannel, ownership: ownership)
            case .ping(let value):
                try await send(
                    SonyRemoteProtocolCodec.pingResponse(value), on: controlChannel, ownership: ownership)
            case .powerState(let isOn):
                guard let device else {
                    throw SonyPairingCoordinatorError.invalidRemoteResponse
                }
                return SonyRemoteDevice(
                    model: device.model, softwareVersion: device.softwareVersion,
                    negotiatedFeatures: device.negotiatedFeatures,
                    powerState: isOn ? .on : .standby,
                    reportedFeatures: device.reportedFeatures
                )
            case .imeFocus, .imeCounters, .other:
                continue
            }
        }
        throw SonyPairingCoordinatorError.remoteHandshakeTimedOut
    }

    private static func send(
        _ message: Data, on channel: any SonyTLSChanneling, ownership: SonyTLSChannelOwnership?
    ) async throws {
        try Task.checkCancellation()
        if let ownership {
            try await channel.send(message, ownership: ownership)
        } else {
            try await channel.send(message)
        }
        try Task.checkCancellation()
        try ownership?.requireCurrent()
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
