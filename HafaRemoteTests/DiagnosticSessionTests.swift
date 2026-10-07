import Foundation
import Testing

@testable import HafaRemote

@MainActor
struct DiagnosticSessionTests {
    @Test("Initial snapshots retain state-production ownership during replacement teardown")
    func snapshotCannotRelabelOldStateWithNewRequest() async throws {
        let teardown = DiagnosticOwnershipGate()
        let controller = RemoteSessionController(driver: DiagnosticOwnershipFixture(secondTeardown: teardown))
        let firstRequest = UUID()
        let secondRequest = UUID()
        await controller.connect(to: try candidate("synthetic-a"), requestID: firstRequest)
        let replacement = Task {
            await controller.connect(to: try candidate("synthetic-b"), requestID: secondRequest)
        }
        await teardown.waitUntilStarted()
        var updates = await controller.stateUpdates().makeAsyncIterator()
        let snapshot = try #require(await updates.next())
        #expect(snapshot.requestID == firstRequest)
        #expect(!(await controller.ownsStateUpdate(snapshot)))
        await teardown.release()
        try await replacement.value
        await controller.disconnect()
    }

    @Test("Queued candidate A state cannot adopt candidate B's diagnostic request")
    func queuedCandidateUpdatesKeepProducerOwnership() async throws {
        let gate = DiagnosticOwnershipGate()
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: DiagnosticOwnershipFixture()),
            beforeProjectingState: { state in if state == .idle { await gate.wait() } },
            diagnostics: recorder
        )
        await gate.waitUntilStarted()
        await store.connect(to: try candidate("synthetic-a"))
        await store.connect(to: try candidate("synthetic-b"))
        await gate.release()
        await waitUntil { store.connectedTV?.reportedDeviceID == "synthetic-b" }
        #expect(store.diagnosticMetadata.tvModel == "MODEL_B")
        #expect(recorder.events.filter { $0.kind == .connectionReady }.count == 1)
        #expect(!recorder.report(metadata: store.diagnosticMetadata).text.contains("MODEL_A"))
        await store.disconnect()
    }

    @Test("A cleared queued connection does not repopulate collection when projected")
    func clearInvalidatesAlreadyProducedStateEvents() async throws {
        let gate = DiagnosticOwnershipGate()
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: DiagnosticOwnershipFixture()),
            beforeProjectingState: { state in if state == .idle { await gate.wait() } },
            diagnostics: recorder
        )
        await gate.waitUntilStarted()
        await store.connect(to: try candidate("synthetic-a"))
        recorder.clear()
        await gate.release()
        await waitUntil { store.connectedTV?.reportedDeviceID == "synthetic-a" }
        #expect(recorder.events.isEmpty)
        try await store.send(.home)
        #expect(recorder.events.map(\.kind) == [.commandSent])
        await store.disconnect()
    }

    @Test(
        "Late command/text completions cannot resurrect discarded activity", arguments: [false, true],
        [false, true])
    func collectionLeaseSurvivesAsyncDelivery(isText: Bool, togglesConsent: Bool) async throws {
        let gate = DiagnosticOwnershipGate()
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: DiagnosticOwnershipFixture(delivery: gate)),
            diagnostics: recorder
        )
        await store.connect(to: try candidate("synthetic-a"))
        await waitUntil { store.connectedTV != nil }
        let delivery = Task { @MainActor in
            if isText {
                try await store.sendText(RemoteTextInput("synthetic private input"))
            } else {
                try await store.send(.home)
            }
        }
        await gate.waitUntilStarted()
        if togglesConsent {
            recorder.setEnabled(false)
            recorder.setEnabled(true)
        } else {
            recorder.clear()
        }
        #expect(recorder.events.isEmpty)
        await gate.release()
        try await delivery.value
        #expect(recorder.events.isEmpty)
        try await store.send(.home)
        #expect(recorder.events.map(\.kind) == [.commandSent])
        await store.disconnect()
    }

    @Test("A connection begun before Clear cannot record its later readiness")
    func clearInvalidatesInFlightConnection() async throws {
        let gate = DiagnosticOwnershipGate()
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: DiagnosticOwnershipFixture(connection: gate)),
            diagnostics: recorder
        )
        let connection = Task { @MainActor in await store.connect(to: try candidate("synthetic-a")) }
        await gate.waitUntilStarted()
        await waitUntil { store.state == .connecting }
        recorder.clear()
        await gate.release()
        try await connection.value
        await waitUntil { store.connectedTV != nil }
        #expect(recorder.events.isEmpty)
        await store.disconnect()
    }

    private func candidate(_ identity: String) throws -> TVConnectionTarget {
        TVConnectionTarget(
            brand: .samsung, reportedDeviceID: identity,
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46"), controlPort: 8002)
    }

    @Test("Returning to TV A cannot revive its old wake collection lease")
    func tvSwitchInvalidatesOldCollectionEvenAfterReturn() async throws {
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: DiagnosticOwnershipFixture()), diagnostics: recorder)
        let first = try target("synthetic-a")
        let second = try target("synthetic-b")
        await store.connect(to: first)
        await waitUntil { store.connectedTV?.reportedDeviceID == first.reportedDeviceID }
        let oldWake = store.recordWakeRequested(for: "samsung:synthetic-a")
        await store.connect(to: second)
        await waitUntil { store.connectedTV?.reportedDeviceID == second.reportedDeviceID }
        await store.connect(to: first)
        await waitUntil { store.connectedTV?.reportedDeviceID == first.reportedDeviceID }
        let events = recorder.events
        store.recordWakeUnavailable(for: "samsung:synthetic-a", collection: oldWake)
        #expect(recorder.events == events)
        await store.disconnect()
    }

    @Test("A live session records only fixed events and clears the prior TV on switching")
    func sessionEventsAreScopedAndOptIn() async throws {
        let recorder = DiagnosticRecorder()
        let driver = DiagnosticSessionFixture()
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: driver), diagnostics: recorder)
        let first = try target("synthetic-first-tv")
        await store.connect(to: first)
        await waitUntil { store.connectedTV?.reportedDeviceID == first.reportedDeviceID }
        try await store.send(.select)
        #expect(recorder.events.isEmpty)

        recorder.setEnabled(true)
        try await store.send(.volumeUp)
        #expect(recorder.events.map(\.kind) == [.commandSent])
        let second = try target("synthetic-second-tv")
        await store.connect(to: second)
        await waitUntil { store.connectedTV?.reportedDeviceID == second.reportedDeviceID }
        #expect(!recorder.events.contains(where: { $0.kind == .commandSent }))
        #expect(recorder.events.contains(where: { $0.kind == .connectionReady }))
        let report = recorder.report(metadata: store.diagnosticMetadata).text
        #expect(report.contains("SYNTHETIC_MODEL"))
        #expect(!report.contains("Synthetic Room Name"))
        #expect(!report.contains("synthetic-second-tv"))
        #expect(!report.contains("192.0.2.46"))
        recorder.setEnabled(false)
        #expect(recorder.events.isEmpty)
        await store.disconnect()
    }

    @Test("Text diagnostics omit input and error payloads, and disconnected metadata is omitted")
    func textEventsNeverContainTextOrNames() async throws {
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let driver = DiagnosticSessionFixture()
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: driver), diagnostics: recorder)
        await store.connect(to: try target("synthetic-text-tv"))
        await waitUntil { store.connectedTV != nil }
        try await store.sendText(RemoteTextInput("synthetic private entered text"))
        #expect(recorder.events.contains(where: { $0.kind == .textSent }))
        #expect(
            !recorder.report(metadata: store.diagnosticMetadata).text.contains(
                "synthetic private entered text"))
        await driver.failNextText()
        await #expect(throws: SyntheticDiagnosticFailure.self) {
            try await store.sendText(RemoteTextInput("synthetic second private text"))
        }
        #expect(recorder.events.contains(where: { $0.kind == .textDeliveryFailed }))
        #expect(
            !recorder.report(metadata: store.diagnosticMetadata).text.contains("synthetic credential error"))
        await store.disconnect(clearRememberedTV: false)
        await waitUntil { store.state == .idle }
        #expect(store.diagnosticMetadata.tvModel == "Not included")
        #expect(store.diagnosticMetadata.tvFirmware == "Not included")
    }

    private func target(_ identity: String) throws -> TVConnectionTarget {
        TVConnectionTarget(
            brand: .samsung, reportedDeviceID: identity,
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46"), controlPort: 8002,
            expectedSavedDeviceID: identity
        )
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<5_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("The in-memory session projection did not settle")
    }
}

private struct SyntheticDiagnosticFailure: LocalizedError {
    var errorDescription: String? { "synthetic credential error 203.0.113.46" }
}

private actor DiagnosticSessionFixture: RemoteSessionDriving {
    private var shouldFailText = false
    func failNextText() { shouldFailText = true }
    func connect(addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void)
        throws -> ConnectedTV
    {
        throw TVDriverError.savedDeviceIdentityMismatch
    }

    func connect(
        to target: TVConnectionTarget, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) -> ConnectedTV {
        ConnectedTV(
            reportedDeviceID: target.reportedDeviceID, address: target.address,
            displayName: "Synthetic Room Name",
            modelName: "SYNTHETIC_MODEL", firmwareVersion: "1.2.3"
        )
    }

    func send(_ command: RemoteCommand) {}
    func sendText(_ input: RemoteTextInput) throws {
        if shouldFailText { throw SyntheticDiagnosticFailure() }
    }
    func forget(addressText: String) {}
    func disconnect() {}
}

private actor DiagnosticOwnershipGate {
    private var isOpen = false
    private var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !isOpen else { return }
        hasStarted = true
        started?.resume()
        started = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor DiagnosticOwnershipFixture: RemoteSessionDriving {
    private let delivery: DiagnosticOwnershipGate?
    private let connection: DiagnosticOwnershipGate?
    private let secondTeardown: DiagnosticOwnershipGate?
    private var teardownCount = 0
    init(
        delivery: DiagnosticOwnershipGate? = nil, connection: DiagnosticOwnershipGate? = nil,
        secondTeardown: DiagnosticOwnershipGate? = nil
    ) {
        self.delivery = delivery
        self.connection = connection
        self.secondTeardown = secondTeardown
    }
    func connect(addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void)
        throws -> ConnectedTV
    {
        throw TVDriverError.savedDeviceIdentityMismatch
    }
    func connect(
        to target: TVConnectionTarget, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async -> ConnectedTV {
        await connection?.wait()
        return ConnectedTV(
            reportedDeviceID: target.reportedDeviceID, address: target.address,
            modelName: target.reportedDeviceID == "synthetic-a" ? "MODEL_A" : "MODEL_B",
            firmwareVersion: "1.2.3")
    }
    func send(_ command: RemoteCommand) async { await delivery?.wait() }
    func sendText(_ input: RemoteTextInput) async { await delivery?.wait() }
    func forget(addressText: String) {}
    func disconnect() async {
        teardownCount += 1
        if teardownCount == 2 { await secondTeardown?.wait() }
    }
}

@MainActor
struct CancelledRequestProbe {
    @Test("Canceled provisional connect must not orphan subsequent producer updates")
    func canceledConnectBeforeActorAdoption() async throws {
        let gate = RemovalGate()
        let driver = ProbeDriver(gate: gate)
        let controller = RemoteSessionController(driver: driver)
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(controller: controller, diagnostics: recorder)
        let address = try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46")
        let first = TVConnectionTarget(
            brand: .samsung, reportedDeviceID: "synthetic-a", address: address, controlPort: 8002,
            expectedSavedDeviceID: "synthetic-a")
        let second = TVConnectionTarget(
            brand: .samsung, reportedDeviceID: "synthetic-b", address: address, controlPort: 8002,
            expectedSavedDeviceID: "synthetic-b")
        await store.connect(to: first)
        await settle { store.connectedTV?.reportedDeviceID == "synthetic-a" }
        let removal = Task { @MainActor in
            try await store.removePairingCredential(
                for: address.rawValue,
                reportedDeviceID: "synthetic-unselected", brand: .samsung)
        }
        await gate.waitUntilStarted()
        let replacement = Task { @MainActor in await store.connect(to: second) }
        await settle {
            recorder.events.map(\.kind) == [.connectionStarted]
                && store.diagnosticMetadata.tvModel == "Not included"
        }
        replacement.cancel()
        await replacement.value
        await gate.release()
        try await removal.value
        await store.applicationDidEnterBackground()
        #expect(await controller.state == .offline)
        await settle { store.state == .offline }
        #expect(
            store.state == .offline,
            "Store still advertises the former connected session after canceled request B")
        await store.disconnect()
    }
    private func settle(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<5000 {
            if predicate() { return }
            await Task.yield()
        }
    }
}
private actor RemovalGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}
private actor ProbeDriver: RemoteSessionDriving {
    let gate: RemovalGate
    init(gate: RemovalGate) { self.gate = gate }
    func connect(
        to target: TVConnectionTarget,
        onWaitingForApproval: @escaping @MainActor @Sendable () async -> Void
    ) -> ConnectedTV {
        ConnectedTV(
            reportedDeviceID: target.reportedDeviceID, address: target.address,
            modelName: "SYNTHETIC_MODEL", firmwareVersion: "1.0")
    }
    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @MainActor @Sendable () async -> Void
    ) throws -> ConnectedTV {
        throw TVDriverError.savedDeviceIdentityMismatch
    }
    func removeCredential(addressText: String, reportedDeviceID: String?, brand: TVBrand) async {
        await gate.wait()
    }
    func send(_ command: RemoteCommand) {}
    func forget(addressText: String) {}
    func disconnect() {}
}

@MainActor
struct ClearFailedConnectionProbe {
    @Test("Pre-clear attempt failure must retain its original collection lease", arguments: [false, true])
    func oldFailureMustNotRepopulate(togglesConsent: Bool) async throws {
        let gate = FailureGate()
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: FailureDriver(gate: gate)), diagnostics: recorder)
        let target = TVConnectionTarget(
            brand: .samsung, reportedDeviceID: "synthetic-a",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46"), controlPort: 8002,
            expectedSavedDeviceID: "synthetic-a")
        let connection = Task { @MainActor in await store.connect(to: target) }
        await gate.waitUntilStarted()
        for _ in 0..<5000 {
            if store.state == .connecting { break }
            await Task.yield()
        }
        if togglesConsent {
            recorder.setEnabled(false)
            recorder.setEnabled(true)
        } else {
            recorder.clear()
        }
        #expect(recorder.events.isEmpty)
        await gate.release()
        await connection.value
        for _ in 0..<5000 {
            if store.state == .savedPairingRejected { break }
            await Task.yield()
        }
        #expect(store.state == .savedPairingRejected)
        #expect(recorder.events.isEmpty, "Old attempt failure repopulated erased or re-consented collection")
        await store.disconnect()
    }
}
private actor FailureGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}
private actor FailureDriver: RemoteSessionDriving {
    let gate: FailureGate
    init(gate: FailureGate) { self.gate = gate }
    func connect(
        to target: TVConnectionTarget,
        onWaitingForApproval: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> ConnectedTV {
        await gate.wait()
        throw SamsungPairingCoordinatorError.savedPairingRejected
    }
    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @MainActor @Sendable () async -> Void
    ) throws -> ConnectedTV {
        throw SamsungPairingCoordinatorError.savedPairingRejected
    }
    func send(_ command: RemoteCommand) {}
    func forget(addressText: String) {}
    func disconnect() {}
}

@MainActor
struct DiagnosticAdmissionAndActivityTests {
    @Test("Canceling provisional B cannot overwrite a newer provisional C")
    func newerAdmissionWinsRestoration() async throws {
        let removalGate = RemovalGate()
        let driver = ProbeDriver(gate: removalGate)
        let controller = RemoteSessionController(driver: driver)
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(controller: controller, diagnostics: recorder)
        await store.connect(to: try target("synthetic-a"))
        await settle { store.connectedTV?.reportedDeviceID == "synthetic-a" }
        let removal = Task {
            try await store.removePairingCredential(
                for: "192.0.2.46", reportedDeviceID: "synthetic-other", brand: .samsung)
        }
        await removalGate.waitUntilStarted()
        let second = Task { await store.connect(to: try target("synthetic-b")) }
        await settle { store.diagnosticMetadata.tvModel == "Not included" }
        let beforeThird = recorder.captureCollection()
        let third = Task { await store.connect(to: try target("synthetic-c")) }
        await settle { recorder.captureCollection() != beforeThird }
        second.cancel()
        try await second.value
        await removalGate.release()
        try await removal.value
        try await third.value
        await settle { store.connectedTV?.reportedDeviceID == "synthetic-c" }
        #expect(store.connectedTV?.reportedDeviceID == "synthetic-c")
        #expect(store.diagnosticMetadata.tvModel == "SYNTHETIC_MODEL")
        await store.applicationDidEnterBackground()
        await settle { store.state == .offline }
        #expect(store.state == .offline)
        await store.disconnect()
    }

    @Test("Canceled connectAndWait before admission restores the actual producer")
    func canceledWaiterRestoresProducer() async throws {
        let gate = RemovalGate()
        let controller = RemoteSessionController(driver: ProbeDriver(gate: gate))
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(controller: controller, diagnostics: recorder)
        await store.connect(to: try target("synthetic-a"))
        await settle { store.connectedTV != nil }
        let removal = Task {
            try await store.removePairingCredential(
                for: "192.0.2.46", reportedDeviceID: "synthetic-other", brand: .samsung)
        }
        await gate.waitUntilStarted()
        let oldLease = recorder.captureCollection()
        let waiting = Task {
            try await store.connectAndWait(to: try target("synthetic-b"), timeout: .seconds(5))
        }
        await settle { recorder.captureCollection() != oldLease }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await gate.release()
        try await removal.value
        await store.applicationDidEnterBackground()
        await settle { store.state == .offline }
        #expect(store.state == .offline)
        await store.disconnect()
    }

    @Test("connectAndWait ignores initial same-TV and raw-address snapshots", arguments: [false, true])
    func waiterRequiresItsNewProducer(isRawAddress: Bool) async throws {
        let teardown = DiagnosticOwnershipGate()
        let driver = DiagnosticActivityFixture(secondTeardown: teardown)
        let controller = RemoteSessionController(driver: driver)
        let store = RemoteSessionStore(controller: controller)
        let saved = try target("synthetic-a")
        await store.connect(to: saved)
        await settle { store.connectedTV != nil }
        let completion = DiagnosticCompletionFlag()
        let waiting = Task { @MainActor in
            let value: ConnectedTV
            if isRawAddress {
                value = try await store.connectAndWait(to: "192.0.2.46", timeout: .seconds(5))
            } else {
                value = try await store.connectAndWait(to: saved, timeout: .seconds(5))
            }
            await completion.finish()
            return value
        }
        await teardown.waitUntilStarted()
        #expect(!(await completion.finished))
        await teardown.release()
        let connected = try await waiting.value
        #expect(connected.reportedDeviceID == "synthetic-a")
        #expect(await driver.connectionCount == 2)
        await store.disconnect()
    }

    @Test(
        "Held health outcomes use health initiation, while new health activity can record",
        arguments: [false, true])
    func healthLeaseIsPerProbe(togglesConsent: Bool) async throws {
        let clock = DiagnosticActivityClock()
        let health = DiagnosticOwnershipGate()
        let driver = DiagnosticActivityFixture(health: health)
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: driver, clock: clock, configuration: configuration()),
            diagnostics: recorder)
        await store.connect(to: try target("synthetic-a"))
        await settle { store.connectedTV != nil }
        await advance(clock, duration: .seconds(17))
        await health.waitUntilStarted()
        clear(recorder, togglesConsent: togglesConsent)
        await health.release()
        await settle { store.state == .offline }
        #expect(recorder.events.isEmpty)
        await store.disconnect()

        let freshClock = DiagnosticActivityClock()
        let freshHealth = DiagnosticOwnershipGate()
        let freshDriver = DiagnosticActivityFixture(health: freshHealth)
        let freshStore = RemoteSessionStore(
            controller: RemoteSessionController(
                driver: freshDriver, clock: freshClock, configuration: configuration()), diagnostics: recorder
        )
        await freshStore.connect(to: try target("synthetic-a"))
        await settle { freshStore.connectedTV != nil }
        recorder.clear()
        await advance(freshClock, duration: .seconds(17))
        await freshHealth.waitUntilStarted()
        await freshHealth.release()
        await settle { freshStore.state == .offline }
        #expect(recorder.events.map(\.kind) == [.connectionUnavailable])
        await freshStore.disconnect()
    }

    @Test("A pre-Clear network-grace outcome cannot populate the new collection", arguments: [false, true])
    func networkGraceRetainsOrigin(togglesConsent: Bool) async throws {
        let clock = DiagnosticActivityClock()
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(
                driver: DiagnosticActivityFixture(), clock: clock, configuration: configuration()),
            diagnostics: recorder)
        await store.connect(to: try target("synthetic-a"))
        await settle { store.connectedTV != nil }
        await store.networkReachabilityChanged(isReachable: false)
        clear(recorder, togglesConsent: togglesConsent)
        await advance(clock, duration: .seconds(19))
        await settle { store.state == .offline }
        #expect(recorder.events.isEmpty)
        await store.disconnect()
    }

    @Test("Delayed lifecycle offline completion cannot reacquire consent", arguments: [false, true])
    func lifecycleCompletionKeepsOrigin(togglesConsent: Bool) async throws {
        let command = DiagnosticOwnershipGate()
        let driver = DiagnosticActivityFixture(command: command)
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: driver), diagnostics: recorder)
        await store.connect(to: try target("synthetic-a"))
        await settle { store.connectedTV != nil }
        let delivery = Task { try await store.send(.home) }
        await command.waitUntilStarted()
        let background = Task { await store.applicationDidEnterBackground() }
        await settle { recorder.events.contains { $0.kind == .appBackgrounded } }
        clear(recorder, togglesConsent: togglesConsent)
        await command.release()
        _ = await delivery.result
        await background.value
        await settle { store.state == .offline }
        #expect(recorder.events.isEmpty)
        await store.disconnect()
    }

    @Test("An automatic connection failure retains the attempt's original lease", arguments: [false, true])
    func automaticReconnectFailureIsNotNewActivity(togglesConsent: Bool) async throws {
        let secondConnection = DiagnosticOwnershipGate()
        let driver = DiagnosticActivityFixture(secondConnection: secondConnection)
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        let store = RemoteSessionStore(
            controller: RemoteSessionController(driver: driver), diagnostics: recorder)
        await store.connect(to: try target("synthetic-a"))
        await settle { store.connectedTV != nil }
        await store.applicationDidEnterBackground()
        await settle { store.state == .offline }
        let foreground = Task { await store.applicationWillEnterForeground() }
        await secondConnection.waitUntilStarted()
        clear(recorder, togglesConsent: togglesConsent)
        await secondConnection.release()
        await foreground.value
        await settle { store.state == .savedPairingRejected }
        #expect(recorder.events.isEmpty)
        await store.disconnect()
    }

    private func clear(_ recorder: DiagnosticRecorder, togglesConsent: Bool) {
        if togglesConsent {
            recorder.setEnabled(false)
            recorder.setEnabled(true)
        } else {
            recorder.clear()
        }
    }
    private func target(_ identifier: String) throws -> TVConnectionTarget {
        TVConnectionTarget(
            brand: .samsung, reportedDeviceID: identifier,
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46"), controlPort: 8002,
            expectedSavedDeviceID: identifier)
    }
    private func configuration() -> RemoteSessionConfiguration {
        RemoteSessionConfiguration(
            connectionTimeout: .seconds(5), pairingTimeout: .seconds(5), commandTimeout: .seconds(5),
            disconnectTimeout: .seconds(5), pairingRemovalTimeout: .seconds(5), reconnectDelays: [],
            repeatsLastReconnectDelay: false, healthCheckInterval: .seconds(17),
            healthCheckTimeout: .seconds(5), healthCheckRetryDelay: .seconds(18), healthFailureThreshold: 1,
            networkLossGracePeriod: .seconds(19))
    }
    private func settle(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<5000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("The deterministic projection did not settle")
    }
    private func advance(_ clock: DiagnosticActivityClock, duration: Duration) async {
        for _ in 0..<5000 {
            if await clock.fire(duration) { return }
            await Task.yield()
        }
        Issue.record("The requested clock waiter was not installed")
    }
}

private actor DiagnosticCompletionFlag {
    private(set) var finished = false
    func finish() { finished = true }
}

private actor DiagnosticActivityClock: RemoteSessionClock {
    private struct Sleeper {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private var sleepers: [UUID: Sleeper] = [:]
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(duration: duration, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func fire(_ duration: Duration) -> Bool {
        guard let (id, sleeper) = sleepers.first(where: { $0.value.duration == duration }) else {
            return false
        }
        sleepers[id] = nil
        sleeper.continuation.resume()
        return true
    }
    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor DiagnosticActivityFixture: RemoteSessionDriving {
    private let secondTeardown: DiagnosticOwnershipGate?
    private let health: DiagnosticOwnershipGate?
    private let command: DiagnosticOwnershipGate?
    private let secondConnection: DiagnosticOwnershipGate?
    private var teardowns = 0
    private(set) var connectionCount = 0
    init(
        secondTeardown: DiagnosticOwnershipGate? = nil, health: DiagnosticOwnershipGate? = nil,
        command: DiagnosticOwnershipGate? = nil, secondConnection: DiagnosticOwnershipGate? = nil
    ) {
        self.secondTeardown = secondTeardown
        self.health = health
        self.command = command
        self.secondConnection = secondConnection
    }
    func connect(
        to target: TVConnectionTarget, onWaitingForApproval: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> ConnectedTV {
        connectionCount += 1
        if connectionCount == 2, let secondConnection {
            await secondConnection.wait()
            throw SamsungPairingCoordinatorError.savedPairingRejected
        }
        return television(target.reportedDeviceID)
    }
    func connect(addressText: String, onWaitingForApproval: @escaping @MainActor @Sendable () async -> Void)
        async throws -> ConnectedTV
    {
        connectionCount += 1
        return television("synthetic-a")
    }
    private func television(_ id: String) -> ConnectedTV {
        ConnectedTV(
            reportedDeviceID: id,
            address: try! PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46"),
            modelName: "SYNTHETIC_MODEL", firmwareVersion: "1.0")
    }
    func checkConnection() async throws {
        if let health {
            await health.wait()
            throw SamsungConnectionError.notConnected
        }
    }
    func send(_ command: RemoteCommand) async { await self.command?.wait() }
    func sendText(_ input: RemoteTextInput) {}
    func forget(addressText: String) {}
    func disconnect() async {
        teardowns += 1
        if teardowns == 2 { await secondTeardown?.wait() }
    }
}
