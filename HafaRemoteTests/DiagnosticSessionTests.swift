import Foundation
import Testing

@testable import HafaRemote

@MainActor
struct DiagnosticSessionTests {
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
