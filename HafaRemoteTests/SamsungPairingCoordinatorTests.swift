import Foundation
import Testing

@testable import HafaRemote

struct SamsungPairingCoordinatorTests {
    @Test("The select convenience forwards one semantic select command")
    func selectConvenienceForwardsSemanticCommand() async throws {
        let coordinator = SetupCoordinatorStub(suspendsPairing: false)

        try await coordinator.sendSelect()

        #expect(await coordinator.sentCommands == [.select])
    }

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
        #expect(tv.reportedDeviceID == "synthetic-device-id")
        #expect(savedCredential == issuedCredential)
        #expect(approvalCount == 1)
    }

    @Test("A legacy address-keyed credential is discarded before new approval")
    func discardsLegacyCredentialBeforeNewApproval() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let legacyCredential = try SamsungPairingCredential(
            token: "legacy-token",
            certificateSHA256: Data(repeating: 15, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.seedLegacy(legacyCredential, for: address)
        let replacementCredential = try SamsungPairingCredential(
            token: "replacement-token",
            certificateSHA256: Data(repeating: 18, count: 32)
        )
        let transport = StubSamsungTransport(issuedCredential: replacementCredential)
        let approvalRecorder = ApprovalRecorder()
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        _ = try await coordinator.pair(addressText: address.rawValue) {
            approvalRecorder.record()
        }

        #expect(await transport.presentedCredential == nil)
        #expect(await store.credential(for: address) == replacementCredential)
        #expect(await store.legacyCredential(for: address) == nil)
        #expect(await approvalRecorder.count == 1)
    }

    @Test("An address reused by another Samsung TV never inherits its credential")
    func preventsCredentialCrossoverAfterAddressReuse() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let oldIdentity = try SamsungPairingCredentialIdentity(reportedDeviceID: "old-tv")
        let oldCredential = try SamsungPairingCredential(
            token: "old-tv-token",
            certificateSHA256: Data(repeating: 16, count: 32)
        )
        let newCredential = try SamsungPairingCredential(
            token: "new-tv-token",
            certificateSHA256: Data(repeating: 17, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.save(oldCredential, for: oldIdentity)
        let transport = StubSamsungTransport(issuedCredential: newCredential)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(reportedDeviceID: "new-tv"),
            credentialStore: store,
            transport: transport
        )

        _ = try await coordinator.pair(addressText: address.rawValue)

        #expect(await transport.presentedCredential == nil)
        #expect(
            await store.credential(
                for: oldIdentity,
                discardingLegacyCredentialFor: address
            ) == oldCredential)
    }

    @Test("A stable credential lookup also discards the legacy address record")
    func stableCredentialLookupDiscardsLegacyAddressRecord() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let identity = try SamsungPairingCredentialIdentity(
            reportedDeviceID: "synthetic-device-id"
        )
        let stableCredential = try SamsungPairingCredential(
            token: "stable-token",
            certificateSHA256: Data(repeating: 20, count: 32)
        )
        let legacyCredential = try SamsungPairingCredential(
            token: "legacy-token",
            certificateSHA256: Data(repeating: 21, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.save(stableCredential, for: identity)
        await store.seedLegacy(legacyCredential, for: address)
        let transport = StubSamsungTransport(issuedCredential: stableCredential)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        _ = try await coordinator.pair(addressText: address.rawValue)

        #expect(await transport.presentedCredential == stableCredential)
        #expect(await store.legacyCredential(for: address) == nil)
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

        try await coordinator.forget(
            addressText: address.rawValue,
            reportedDeviceID: "synthetic-device-id"
        )
        let credentialAfterForget = await store.credential(for: address)
        #expect(credentialAfterForget == nil)
    }

    @Test("Forgetting a persisted pairing does not require the TV to be online")
    func forgetsPersistedIdentityWhileTVIsOffline() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let identity = try SamsungPairingCredentialIdentity(
            reportedDeviceID: "offline-tv"
        )
        let credential = try SamsungPairingCredential(
            token: "offline-token",
            certificateSHA256: Data(repeating: 19, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.save(credential, for: identity)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: OfflineSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: StubSamsungTransport(issuedCredential: credential)
        )

        try await coordinator.forget(
            addressText: address.rawValue,
            reportedDeviceID: identity.reportedDeviceID
        )

        #expect(
            await store.credential(
                for: identity,
                discardingLegacyCredentialFor: address
            ) == nil
        )
    }

    @Test("Address-only forget never removes a stable TV credential")
    func addressOnlyForgetPreservesStableCredential() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let identity = try SamsungPairingCredentialIdentity(
            reportedDeviceID: "synthetic-device-id"
        )
        let stableCredential = try SamsungPairingCredential(
            token: "stable-token",
            certificateSHA256: Data(repeating: 22, count: 32)
        )
        let store = InMemorySamsungCredentialStore()
        await store.save(stableCredential, for: identity)
        let transport = StubSamsungTransport(issuedCredential: stableCredential)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )
        _ = try await coordinator.pair(addressText: address.rawValue)

        try await coordinator.forget(addressText: address.rawValue)

        #expect(
            await store.credential(
                for: identity,
                discardingLegacyCredentialFor: address
            ) == stableCredential
        )
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

    @Test("A failed credential save disconnects before an immediate retry")
    func saveFailureDisconnectsAndAllowsRetry() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let issuedCredential = try SamsungPairingCredential(
            token: "synthetic-token",
            certificateSHA256: Data(repeating: 12, count: 32)
        )
        let store = FailFirstSaveCredentialStore()
        let transport = AttemptAwareSamsungTransport(issuedCredential: issuedCredential)
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: StubSamsungDeviceInfoProvider(),
            credentialStore: store,
            transport: transport
        )

        await #expect(throws: SyntheticCredentialStoreError.writeFailed) {
            try await coordinator.pair(addressText: address.rawValue)
        }
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

    @Test("Cancellation restores an existing credential after a refreshed save")
    func cancellationRestoresExistingCredential() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let previousCredential = try SamsungPairingCredential(
            token: "previous-token",
            certificateSHA256: Data(repeating: 13, count: 32)
        )
        let refreshedCredential = try SamsungPairingCredential(
            token: "refreshed-token",
            certificateSHA256: Data(repeating: 13, count: 32)
        )
        let store = SuspendedSaveCredentialStore()
        await store.seed(previousCredential, for: address)
        let transport = AttemptAwareSamsungTransport(issuedCredential: refreshedCredential)
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
        #expect(await store.credential(for: address) == previousCredential)
    }

    @Test("A failed existing-credential restore still preserves cancellation")
    func failedRestorePreservesCancellation() async throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let previousCredential = try SamsungPairingCredential(
            token: "previous-token",
            certificateSHA256: Data(repeating: 14, count: 32)
        )
        let refreshedCredential = try SamsungPairingCredential(
            token: "refreshed-token",
            certificateSHA256: Data(repeating: 14, count: 32)
        )
        let store = SuspendedSaveCredentialStore(rollbackFails: true)
        await store.seed(previousCredential, for: address)
        let transport = AttemptAwareSamsungTransport(issuedCredential: refreshedCredential)
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

private struct StubSamsungDeviceInfoProvider: SamsungDeviceInfoProviding {
    let reportedDeviceID: String

    init(reportedDeviceID: String = "synthetic-device-id") {
        self.reportedDeviceID = reportedDeviceID
    }

    func fetchDeviceInfo(at address: PrivateIPv4Address) async throws -> SamsungDeviceInfo {
        SamsungDeviceInfo(
            reportedDeviceID: reportedDeviceID,
            modelName: "TEST_MODEL_2021",
            firmwareVersion: "1001.2",
            supportsTokenAuthentication: true
        )
    }
}

private struct OfflineSamsungDeviceInfoProvider: SamsungDeviceInfoProviding {
    func fetchDeviceInfo(at address: PrivateIPv4Address) async throws -> SamsungDeviceInfo {
        throw URLError(.notConnectedToInternet)
    }
}

private actor InMemorySamsungCredentialStore: SamsungPairingCredentialStoring {
    private var values: [SamsungPairingCredentialIdentity: SamsungPairingCredential] = [:]
    private var legacyValues: [PrivateIPv4Address: SamsungPairingCredential] = [:]

    func credential(for address: PrivateIPv4Address) -> SamsungPairingCredential? {
        values[Self.syntheticIdentity]
    }

    func save(_ credential: SamsungPairingCredential, for address: PrivateIPv4Address) {
        values[Self.syntheticIdentity] = credential
    }

    func credential(
        for identity: SamsungPairingCredentialIdentity,
        discardingLegacyCredentialFor address: PrivateIPv4Address
    ) -> SamsungPairingCredential? {
        legacyValues[address] = nil
        if let credential = values[identity] {
            return credential
        }
        return nil
    }

    func save(
        _ credential: SamsungPairingCredential,
        for identity: SamsungPairingCredentialIdentity
    ) {
        values[identity] = credential
    }

    func removeCredential(
        for identity: SamsungPairingCredentialIdentity,
        legacyAddress: PrivateIPv4Address
    ) {
        values[identity] = nil
        legacyValues[legacyAddress] = nil
    }

    func removeLegacyCredential(for address: PrivateIPv4Address) {
        legacyValues[address] = nil
    }

    func seedLegacy(_ credential: SamsungPairingCredential, for address: PrivateIPv4Address) {
        legacyValues[address] = credential
    }

    func legacyCredential(for address: PrivateIPv4Address) -> SamsungPairingCredential? {
        legacyValues[address]
    }

    private static var syntheticIdentity: SamsungPairingCredentialIdentity {
        do {
            return try SamsungPairingCredentialIdentity(
                reportedDeviceID: "synthetic-device-id"
            )
        } catch {
            preconditionFailure("The synthetic Samsung identity fixture must be valid.")
        }
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

    func credential(
        for identity: SamsungPairingCredentialIdentity,
        discardingLegacyCredentialFor address: PrivateIPv4Address
    ) async -> SamsungPairingCredential? {
        lookupStartedContinuation.yield()
        return await withCheckedContinuation { continuation in
            lookupContinuation = continuation
        }
    }

    func save(
        _ credential: SamsungPairingCredential,
        for identity: SamsungPairingCredentialIdentity
    ) {
        saveCount += 1
    }

    func removeCredential(
        for identity: SamsungPairingCredentialIdentity,
        legacyAddress: PrivateIPv4Address
    ) {}

    func removeLegacyCredential(for address: PrivateIPv4Address) {}

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
    private var values: [SamsungPairingCredentialIdentity: SamsungPairingCredential] = [:]
    private var saveCallCount = 0
    private let rollbackFails: Bool

    init(rollbackFails: Bool = false) {
        self.rollbackFails = rollbackFails
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        firstSaveStarted = stream
        firstSaveStartedContinuation = continuation
    }

    func credential(for address: PrivateIPv4Address) -> SamsungPairingCredential? {
        values[Self.syntheticIdentity]
    }

    func credential(
        for identity: SamsungPairingCredentialIdentity,
        discardingLegacyCredentialFor address: PrivateIPv4Address
    ) -> SamsungPairingCredential? {
        values[identity]
    }

    func save(
        _ credential: SamsungPairingCredential,
        for identity: SamsungPairingCredentialIdentity
    ) async throws {
        saveCallCount += 1
        if rollbackFails, saveCallCount > 1 {
            throw SyntheticCredentialStoreError.rollbackFailed
        }
        values[identity] = credential
        guard saveCallCount == 1 else { return }

        firstSaveStartedContinuation.yield()
        await withCheckedContinuation { continuation in
            firstSaveContinuation = continuation
        }
    }

    func removeCredential(
        for identity: SamsungPairingCredentialIdentity,
        legacyAddress: PrivateIPv4Address
    ) throws {
        if rollbackFails {
            throw SyntheticCredentialStoreError.rollbackFailed
        }
        values[identity] = nil
    }

    func removeLegacyCredential(for address: PrivateIPv4Address) {}

    func seed(_ credential: SamsungPairingCredential, for address: PrivateIPv4Address) {
        values[Self.syntheticIdentity] = credential
    }

    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
        firstSaveStartedContinuation.finish()
    }

    private static var syntheticIdentity: SamsungPairingCredentialIdentity {
        do {
            return try SamsungPairingCredentialIdentity(
                reportedDeviceID: "synthetic-device-id"
            )
        } catch {
            preconditionFailure("The synthetic Samsung identity fixture must be valid.")
        }
    }
}

private actor FailFirstSaveCredentialStore: SamsungPairingCredentialStoring {
    private var values: [SamsungPairingCredentialIdentity: SamsungPairingCredential] = [:]
    private var shouldFailSave = true

    func credential(for address: PrivateIPv4Address) -> SamsungPairingCredential? {
        values[Self.syntheticIdentity]
    }

    func credential(
        for identity: SamsungPairingCredentialIdentity,
        discardingLegacyCredentialFor address: PrivateIPv4Address
    ) -> SamsungPairingCredential? {
        values[identity]
    }

    func save(
        _ credential: SamsungPairingCredential,
        for identity: SamsungPairingCredentialIdentity
    ) throws {
        if shouldFailSave {
            shouldFailSave = false
            throw SyntheticCredentialStoreError.writeFailed
        }
        values[identity] = credential
    }

    func removeCredential(
        for identity: SamsungPairingCredentialIdentity,
        legacyAddress: PrivateIPv4Address
    ) {
        values[identity] = nil
    }

    func removeLegacyCredential(for address: PrivateIPv4Address) {}

    private static var syntheticIdentity: SamsungPairingCredentialIdentity {
        do {
            return try SamsungPairingCredentialIdentity(
                reportedDeviceID: "synthetic-device-id"
            )
        } catch {
            preconditionFailure("The synthetic Samsung identity fixture must be valid.")
        }
    }
}

private enum SyntheticCredentialStoreError: Error {
    case writeFailed
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
    private(set) var sentCommands: [RemoteCommand] = []

    init(suspendsPairing: Bool) {}

    func pair(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        return PairedSamsungTV(
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.20"),
            modelName: "TEST_MODEL_2021",
            firmwareVersion: "1001.2"
        )
    }

    func send(_ command: RemoteCommand) {
        sentCommands.append(command)
    }

    func forget(addressText: String) {}

    func disconnect() {}
}

@MainActor
private final class ApprovalRecorder {
    private(set) var count = 0

    deinit {}

    func record() {
        count += 1
    }
}
