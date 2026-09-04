import Foundation
import Testing

@testable import HafaRemote

struct SamsungPairingCoordinatorTests {
    @Test("Successful pairing stores the new token and certificate pin")
    func persistsCredentialAfterConnection() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let issuedCredential = try SamsungPairingCredential(
            token: "synthetic-token",
            certificateSHA256: Data(repeating: 7, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        let transport = StubSamsungTransport(issuedCredential: issuedCredential)
        let approvalRecorder = ApprovalRecorder()
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        let tv = try await coordinator.pair(addressText: " 192.168.10.20 ") {
            approvalRecorder.record()
        }
        let savedCredential = await store.credential(for: address)
        let approvalCount = await approvalRecorder.count

        #expect(tv.modelName == "TEST_MODEL_2021")
        #expect(savedCredential == issuedCredential)
        #expect(approvalCount == 1)
    }

    @Test("A select request crosses the driver boundary as one semantic command")
    func sendsSemanticSelect() async throws {
        let issuedCredential = try SamsungPairingCredential(
            token: "synthetic-token",
            certificateSHA256: Data(repeating: 3, count: 32)
        )
        let transport = StubSamsungTransport(issuedCredential: issuedCredential)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: InMemorySamsungCredentialStore(),
            transport: transport
        )

        try await coordinator.sendSelect()
        let commands = await transport.sentCommands

        #expect(commands == [.select])
    }

    @Test("A certificate mismatch never overwrites the remembered credential")
    func preservesCredentialAfterCertificateMismatch() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let existingCredential = try SamsungPairingCredential(
            token: "remembered-token",
            certificateSHA256: Data(repeating: 4, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.save(existingCredential, for: address)
        let transport = StubSamsungTransport(
            issuedCredential: existingCredential,
            connectError: .certificateChanged
        )
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        await #expect(throws: SamsungPairingCoordinatorError.certificateChanged) {
            try await coordinator.pair(addressText: address.rawValue)
        }
        let savedCredential = await store.credential(for: address)
        let presentedCredential = await transport.presentedCredential

        #expect(savedCredential == existingCredential)
        #expect(presentedCredential == existingCredential)
    }

    @Test("A revoked token remains pinned until the user explicitly forgets it")
    func requiresExplicitForgetForRevokedCredential() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let revokedCredential = try SamsungPairingCredential(
            token: "revoked-token",
            certificateSHA256: Data(repeating: 5, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.save(revokedCredential, for: address)
        let transport = StubSamsungTransport(
            issuedCredential: revokedCredential,
            connectError: .denied
        )
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        await #expect(throws: SamsungPairingCoordinatorError.savedPairingRejected) {
            try await coordinator.pair(addressText: address.rawValue)
        }
        let savedCredential = await store.credential(for: address)
        let presentedCredential = await transport.presentedCredential

        #expect(presentedCredential == revokedCredential)
        #expect(savedCredential == revokedCredential)

        try await coordinator.forget(addressText: address.rawValue)
        let credentialAfterForget = await store.credential(for: address)
        #expect(credentialAfterForget == nil)
    }

    @Test("Cancelling in-flight pairing disconnects and saves nothing")
    func cancellationDisconnectsWithoutPersistence() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let store = InMemorySamsungCredentialStore()
        let transport = SuspendedSamsungTransport()
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        let pairing = Task {
            try await coordinator.pair(addressText: address.rawValue)
        }
        var starts = transport.connectStarted.makeAsyncIterator()
        _ = await starts.next()
        pairing.cancel()

        await #expect(throws: CancellationError.self) {
            try await pairing.value
        }
        #expect(await transport.disconnectCount >= 1)
        #expect(await store.credential(for: address) == nil)
    }

    @Test("Cancellation during credential lookup never starts a connection")
    func cancellationDuringCredentialLookupIsOrdered() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let issuedCredential = try SamsungPairingCredential(
            token: "synthetic-token",
            certificateSHA256: Data(repeating: 9, count: 32)
        )
        let store = SuspendedLookupCredentialStore()
        let transport = ObservableSamsungTransport(issuedCredential: issuedCredential)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        let pairing = Task {
            try await coordinator.pair(addressText: address.rawValue)
        }
        var starts = store.lookupStarted.makeAsyncIterator()
        _ = await starts.next()
        pairing.cancel()
        await store.resumeLookup(with: nil)

        await #expect(throws: CancellationError.self) {
            try await pairing.value
        }
        #expect(await transport.connectCount == 0)
        #expect(await transport.disconnectCount >= 1)
        #expect(await store.saveCount == 0)
    }

    @Test("Cancellation during save rolls back before an immediate retry")
    func cancellationDuringSaveRollsBackAndAllowsRetry() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let issuedCredential = try SamsungPairingCredential(
            token: "synthetic-token",
            certificateSHA256: Data(repeating: 10, count: 32)
        )
        let store = SuspendedSaveCredentialStore()
        let transport = AttemptAwareSamsungTransport(issuedCredential: issuedCredential)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        let firstPairing = Task {
            try await coordinator.pair(addressText: address.rawValue)
        }
        var saveStarts = store.firstSaveStarted.makeAsyncIterator()
        _ = await saveStarts.next()
        firstPairing.cancel()
        await store.releaseFirstSave()

        await #expect(throws: CancellationError.self) {
            try await firstPairing.value
        }
        #expect(await store.credential(for: address) == nil)
        #expect(!(await transport.hasActiveConnection))

        _ = try await coordinator.pair(addressText: address.rawValue)
        #expect(await store.credential(for: address) == issuedCredential)
        #expect(await transport.hasActiveConnection)

        await coordinator.disconnect()
    }

    @Test("A rollback failure does not replace pairing cancellation")
    func rollbackFailurePreservesCancellation() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let issuedCredential = try SamsungPairingCredential(
            token: "synthetic-token",
            certificateSHA256: Data(repeating: 11, count: 32)
        )
        let store = SuspendedSaveCredentialStore(rollbackFails: true)
        let transport = AttemptAwareSamsungTransport(issuedCredential: issuedCredential)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        let pairing = Task {
            try await coordinator.pair(addressText: address.rawValue)
        }
        var saveStarts = store.firstSaveStarted.makeAsyncIterator()
        _ = await saveStarts.next()
        pairing.cancel()
        await store.releaseFirstSave()

        await #expect(throws: CancellationError.self) {
            try await pairing.value
        }
    }

    @Test("A failed reconnect keeps the saved credential until a retry succeeds")
    func retryPreservesCredentialUntilSuccess() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let existingCredential = try SamsungPairingCredential(
            token: "remembered-token",
            certificateSHA256: Data(repeating: 8, count: 32)
        )
        let refreshedCredential = try SamsungPairingCredential(
            token: "refreshed-token",
            certificateSHA256: Data(repeating: 8, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.save(existingCredential, for: address)
        let transport = SequencedSamsungTransport(
            issuedCredential: refreshedCredential,
            connectionErrors: [.unavailable]
        )
        let approvalRecorder = ApprovalRecorder()
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        await #expect(throws: SamsungConnectionError.unavailable) {
            try await coordinator.pair(addressText: address.rawValue) {
                approvalRecorder.record()
            }
        }
        #expect(await store.credential(for: address) == existingCredential)

        _ = try await coordinator.pair(addressText: address.rawValue) {
            approvalRecorder.record()
        }
        let approvalCount = await approvalRecorder.count
        #expect(await store.credential(for: address) == refreshedCredential)
        #expect(await transport.presentedCredentials == [existingCredential, existingCredential])
        #expect(approvalCount == 0)
    }

    @Test("Pairing failures never expose the TV address or saved token")
    func failureMessageRedactsPairingMaterial() async throws {
        let addressText = "192.168.10.20"
        let secretToken = "synthetic-secret-token"
        let address = try PrivateIPv4Address(addressText)
        let existingCredential = try SamsungPairingCredential(
            token: secretToken,
            certificateSHA256: Data(repeating: 6, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.save(existingCredential, for: address)
        let transport = StubSamsungTransport(
            issuedCredential: existingCredential,
            connectError: .unavailable
        )
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        do {
            _ = try await coordinator.pair(addressText: addressText)
            Issue.record("Expected pairing to fail")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            #expect(!message.contains(addressText))
            #expect(!message.contains(secretToken))
        }
    }
}

struct SamsungSetupViewModelTests {
    @Test("Disconnect cancels in-flight pairing and restores idle state")
    @MainActor
    func disconnectCancelsPairing() async {
        let coordinator = SetupCoordinatorStub(suspendsPairing: true)
        let model = SamsungSetupViewModel(coordinator: coordinator)
        model.address = "192.168.10.20"

        let connection = Task { await model.connect() }
        var starts = coordinator.pairingStarted.makeAsyncIterator()
        _ = await starts.next()
        await model.disconnect()
        await connection.value

        #expect(model.status == .idle)
        #expect(!model.isControllable)
        #expect(await coordinator.disconnectCount == 1)
    }

    @Test("Disconnect clears a completed connection")
    @MainActor
    func disconnectClearsConnectedState() async {
        let coordinator = SetupCoordinatorStub(suspendsPairing: false)
        let model = SamsungSetupViewModel(coordinator: coordinator)
        model.address = "192.168.10.20"

        await model.connect()
        #expect(model.isControllable)

        await model.disconnect()
        #expect(model.status == .idle)
        #expect(!model.isControllable)
    }
}

private struct StubSamsungDeviceInfoProvider: SamsungDeviceInfoProviding {
    func fetchDeviceInfo(at address: PrivateIPv4Address) async throws -> SamsungDeviceInfo {
        SamsungDeviceInfo(
            modelName: "TEST_MODEL_2021",
            firmwareVersion: "1001.2",
            supportsTokenAuthentication: true
        )
    }
}

private actor InMemorySamsungCredentialStore: SamsungPairingCredentialStoring {
    private var values: [PrivateIPv4Address: SamsungPairingCredential] = [:]

    func credential(for address: PrivateIPv4Address) -> SamsungPairingCredential? {
        values[address]
    }

    func save(_ credential: SamsungPairingCredential, for address: PrivateIPv4Address) {
        values[address] = credential
    }

    func removeCredential(for address: PrivateIPv4Address) {
        values[address] = nil
    }
}

private actor StubSamsungTransport: SamsungTransporting {
    private let issuedCredential: SamsungPairingCredential
    private let connectError: SamsungConnectionError?
    private(set) var sentCommands: [RemoteCommand] = []
    private(set) var presentedCredential: SamsungPairingCredential?

    init(
        issuedCredential: SamsungPairingCredential,
        connectError: SamsungConnectionError? = nil
    ) {
        self.issuedCredential = issuedCredential
        self.connectError = connectError
    }

    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?,
        attemptID: SamsungConnectionAttemptID
    ) throws -> SamsungPairingCredential {
        presentedCredential = credential
        if let connectError {
            throw connectError
        }
        return issuedCredential
    }

    func send(_ command: RemoteCommand) {
        sentCommands.append(command)
    }

    func disconnect() {}

    func disconnect(attemptID: SamsungConnectionAttemptID) {}
}

private actor SuspendedSamsungTransport: SamsungTransporting {
    nonisolated let connectStarted: AsyncStream<Void>
    private let connectStartedContinuation: AsyncStream<Void>.Continuation
    private var connectionContinuation: CheckedContinuation<SamsungPairingCredential, Error>?
    private(set) var disconnectCount = 0

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        connectStarted = stream
        connectStartedContinuation = continuation
    }

    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?,
        attemptID: SamsungConnectionAttemptID
    ) async throws -> SamsungPairingCredential {
        connectStartedContinuation.yield()
        return try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
        }
    }

    func send(_ command: RemoteCommand) {}

    func disconnect() {
        cancelConnection()
    }

    func disconnect(attemptID: SamsungConnectionAttemptID) {
        cancelConnection()
    }

    private func cancelConnection() {
        disconnectCount += 1
        connectionContinuation?.resume(throwing: CancellationError())
        connectionContinuation = nil
        connectStartedContinuation.finish()
    }
}

private actor SequencedSamsungTransport: SamsungTransporting {
    private let issuedCredential: SamsungPairingCredential
    private var connectionErrors: [SamsungConnectionError]
    private(set) var presentedCredentials: [SamsungPairingCredential?] = []

    init(
        issuedCredential: SamsungPairingCredential,
        connectionErrors: [SamsungConnectionError]
    ) {
        self.issuedCredential = issuedCredential
        self.connectionErrors = connectionErrors
    }

    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?,
        attemptID: SamsungConnectionAttemptID
    ) throws -> SamsungPairingCredential {
        presentedCredentials.append(credential)
        if !connectionErrors.isEmpty {
            throw connectionErrors.removeFirst()
        }
        return issuedCredential
    }

    func send(_ command: RemoteCommand) {}

    func disconnect() {}

    func disconnect(attemptID: SamsungConnectionAttemptID) {}
}

private actor SuspendedLookupCredentialStore: SamsungPairingCredentialStoring {
    nonisolated let lookupStarted: AsyncStream<Void>
    private let lookupStartedContinuation: AsyncStream<Void>.Continuation
    private var lookupContinuation: CheckedContinuation<SamsungPairingCredential?, Never>?
    private(set) var saveCount = 0

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lookupStarted = stream
        lookupStartedContinuation = continuation
    }

    func credential(for address: PrivateIPv4Address) async -> SamsungPairingCredential? {
        lookupStartedContinuation.yield()
        return await withCheckedContinuation { continuation in
            lookupContinuation = continuation
        }
    }

    func save(_ credential: SamsungPairingCredential, for address: PrivateIPv4Address) {
        saveCount += 1
    }

    func removeCredential(for address: PrivateIPv4Address) {}

    func resumeLookup(with credential: SamsungPairingCredential?) {
        lookupContinuation?.resume(returning: credential)
        lookupContinuation = nil
        lookupStartedContinuation.finish()
    }
}

private actor ObservableSamsungTransport: SamsungTransporting {
    private let issuedCredential: SamsungPairingCredential
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(issuedCredential: SamsungPairingCredential) {
        self.issuedCredential = issuedCredential
    }

    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?,
        attemptID: SamsungConnectionAttemptID
    ) -> SamsungPairingCredential {
        connectCount += 1
        return issuedCredential
    }

    func send(_ command: RemoteCommand) {}

    func disconnect() {
        disconnectCount += 1
    }

    func disconnect(attemptID: SamsungConnectionAttemptID) {
        disconnectCount += 1
    }
}

private actor SuspendedSaveCredentialStore: SamsungPairingCredentialStoring {
    nonisolated let firstSaveStarted: AsyncStream<Void>
    private let firstSaveStartedContinuation: AsyncStream<Void>.Continuation
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?
    private var values: [PrivateIPv4Address: SamsungPairingCredential] = [:]
    private var saveCallCount = 0
    private let rollbackFails: Bool

    init(rollbackFails: Bool = false) {
        self.rollbackFails = rollbackFails
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        firstSaveStarted = stream
        firstSaveStartedContinuation = continuation
    }

    func credential(for address: PrivateIPv4Address) -> SamsungPairingCredential? {
        values[address]
    }

    func save(_ credential: SamsungPairingCredential, for address: PrivateIPv4Address) async {
        saveCallCount += 1
        values[address] = credential
        guard saveCallCount == 1 else { return }

        firstSaveStartedContinuation.yield()
        await withCheckedContinuation { continuation in
            firstSaveContinuation = continuation
        }
    }

    func removeCredential(for address: PrivateIPv4Address) throws {
        if rollbackFails {
            throw SyntheticCredentialStoreError.rollbackFailed
        }
        values[address] = nil
    }

    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
        firstSaveStartedContinuation.finish()
    }
}

private enum SyntheticCredentialStoreError: Error {
    case rollbackFailed
}

private actor AttemptAwareSamsungTransport: SamsungTransporting {
    private let issuedCredential: SamsungPairingCredential
    private var activeAttemptID: SamsungConnectionAttemptID?

    var hasActiveConnection: Bool {
        activeAttemptID != nil
    }

    init(issuedCredential: SamsungPairingCredential) {
        self.issuedCredential = issuedCredential
    }

    func connect(
        to address: PrivateIPv4Address,
        using credential: SamsungPairingCredential?,
        attemptID: SamsungConnectionAttemptID
    ) -> SamsungPairingCredential {
        activeAttemptID = attemptID
        return issuedCredential
    }

    func send(_ command: RemoteCommand) {}

    func disconnect(attemptID: SamsungConnectionAttemptID) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
    }

    func disconnect() {
        activeAttemptID = nil
    }
}

private actor SetupCoordinatorStub: SamsungPairingCoordinating {
    nonisolated let pairingStarted: AsyncStream<Void>
    private let pairingStartedContinuation: AsyncStream<Void>.Continuation
    private let suspendsPairing: Bool
    private(set) var disconnectCount = 0

    init(suspendsPairing: Bool) {
        self.suspendsPairing = suspendsPairing
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        pairingStarted = stream
        pairingStartedContinuation = continuation
    }

    func pair(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () -> Void
    ) async throws -> PairedSamsungTV {
        await onWaitingForApproval()
        pairingStartedContinuation.yield()
        if suspendsPairing {
            try await Task.sleep(for: .seconds(60))
        }
        pairingStartedContinuation.finish()
        return PairedSamsungTV(
            address: try PrivateIPv4Address("192.168.10.20"),
            modelName: "TEST_MODEL_2021",
            firmwareVersion: "1001.2"
        )
    }

    func sendSelect() {}

    func forget(addressText: String) {}

    func disconnect() {
        disconnectCount += 1
    }
}

@MainActor
private final class ApprovalRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
