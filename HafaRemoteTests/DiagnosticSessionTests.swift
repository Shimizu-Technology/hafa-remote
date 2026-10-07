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
