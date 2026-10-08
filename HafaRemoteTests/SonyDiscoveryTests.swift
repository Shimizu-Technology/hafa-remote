import Foundation
import Testing

@testable import HafaRemote

struct SonyDiscoveryTests {
    @Test("A moved Sony candidate can locate a saved TV without replacing its authenticated identity")
    @MainActor
    func locatesSavedDiscoveryAliasAfterAddressChange() async throws {
        let backend = DiscoveryBackendFixture()
        let store = TVDiscoveryStore(backend: backend)
        let alias = SonyBonjourCandidateMetadata(serviceName: "Synthetic Living Room").reportedIdentifier
        let fingerprint = String(repeating: "a", count: 64)
        let search = Task { await store.findDevice(stableDeviceKey: "sony:\(alias)") }
        while store.state == .idle { await Task.yield() }
        backend.emit(
            .found(
                DiscoveredTV(
                    brand: .sony,
                    reportedIdentifier: alias,
                    displayName: "Synthetic Living Room",
                    modelName: "Synthetic Sony",
                    address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.43"),
                    controlPort: 6466
                )))
        let candidate = try #require(await search.value)
        let rebound = candidate.expectingSavedIdentity(fingerprint)

        #expect(rebound.discoveryIdentifier == alias)
        #expect(rebound.expectedSavedDeviceID == fingerprint)
        #expect(rebound.discoveryDeviceKey == "sony:\(alias)")
        let impostor = ConnectedTV(
            brand: .sony,
            reportedDeviceID: String(repeating: "b", count: 64),
            address: rebound.address,
            modelName: "Synthetic Other Sony",
            firmwareVersion: nil
        )
        #expect(throws: TVDriverError.savedDeviceIdentityMismatch) {
            try rebound.validateConnectedIdentity(impostor)
        }
        store.stop()
    }

    @Test("Sony candidate metadata is bounded, sanitized, and address-independent")
    func candidateMetadata() {
        let rawName = "  Living\u{0000} Room " + String(repeating: "A", count: 100)
        let first = SonyBonjourCandidateMetadata(serviceName: rawName)
        let second = SonyBonjourCandidateMetadata(serviceName: rawName)

        #expect(first == second)
        #expect(first.displayName.count == 80)
        #expect(!first.displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        #expect(first.reportedIdentifier.count == 64)
        #expect(!first.reportedIdentifier.contains("192.168"))
    }

    @Test(
        "Replaced scan callbacks cannot finish a new scan or acquire its diagnostic lease",
        arguments: [false, true], ["restart", "stop", "reconsent"])
    @MainActor
    func replacedScanCannotPublish(_ useComposite: Bool, _ replacement: String) throws {
        let backend = HeldDiscoveryBackendFixture()
        let selectedBackend: any TVDiscoveryBackend =
            useComposite ? CompositeTVDiscoveryBackend(backends: [backend]) : backend
        let store = TVDiscoveryStore(backend: selectedBackend, searchDuration: .seconds(30))
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        var collection = recorder.captureCollection()
        recorder.record(.discoveryStarted, collection: collection)
        store.start()
        let oldCallback = try #require(backend.callbacks.first)
        if replacement == "stop" { store.stop() }
        if replacement == "reconsent" {
            recorder.setEnabled(false)
            recorder.setEnabled(true)
        } else {
            recorder.clear()
        }
        collection = recorder.captureCollection()
        recorder.record(.discoveryStarted, collection: collection)
        store.start()
        let currentCallback = try #require(backend.callbacks.last)
        let oldTV = DiscoveredTV(
            reportedIdentifier: "synthetic-old-scan-tv", displayName: "Synthetic Old TV",
            modelName: "Synthetic Model",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46"))
        // Project actual store transitions as Setup does, retaining the scan's initiating token.
        func publish(
            _ event: TVDiscoveryBackendEvent,
            through callback: @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
        ) {
            let previous = store.state
            callback(event)
            guard store.state != previous else { return }
            switch store.state {
            case .results, .noResults, .permissionDenied, .failed:
                recorder.finishDiscovery(collection: &collection)
            case .idle, .searching:
                break
            }
        }
        for event in [TVDiscoveryBackendEvent.found(oldTV), .finished, .permissionDenied, .failed] {
            publish(event, through: oldCallback)
        }
        #expect(store.state == .searching)
        #expect(store.televisions.isEmpty)
        #expect(recorder.events.map(\.kind) == [.discoveryStarted])
        let newTV = DiscoveredTV(
            reportedIdentifier: "synthetic-current-scan-tv", displayName: "Synthetic Current TV",
            modelName: "Synthetic Model",
            address: try PrivateIPv4Address(documentationAddressForTesting: "198.51.100.46"))
        publish(.found(newTV), through: currentCallback)
        publish(.found(newTV), through: currentCallback)
        publish(.finished, through: currentCallback)
        #expect(store.televisions == [newTV])
        #expect(store.state == .results)
        #expect(recorder.events.map(\.kind) == [.discoveryStarted, .discoveryFinished])
        store.stop()
    }

    @Test("Composite callbacks retain their producer scan before forwarding to the current handler")
    @MainActor
    func compositeRejectsReplacedProducer() throws {
        let backend = HeldDiscoveryBackendFixture()
        let composite = CompositeTVDiscoveryBackend(backends: [backend])
        var oldEventCount = 0
        var currentEventCount = 0
        composite.start { _ in oldEventCount += 1 }
        let oldCallback = try #require(backend.callbacks.first)
        composite.stop()
        composite.start { _ in currentEventCount += 1 }
        let currentCallback = try #require(backend.callbacks.last)
        oldCallback(.finished)
        oldCallback(.permissionDenied)
        oldCallback(.failed)
        #expect(oldEventCount == 0)
        #expect(currentEventCount == 0)
        currentCallback(.finished)
        #expect(currentEventCount == 1)
        composite.stop()
    }

    @Test("Composite discovery waits for every brand backend before failing")
    @MainActor
    func compositeWaitsForAllBackends() {
        let first = DiscoveryBackendFixture()
        let second = DiscoveryBackendFixture()
        let composite = CompositeTVDiscoveryBackend(backends: [first, second])
        var terminalEvents = 0
        composite.start { event in
            switch event {
            case .found: break
            case .finished, .permissionDenied, .failed: terminalEvents += 1
            }
        }
        first.emit(.failed)

        #expect(terminalEvents == 0)

        second.emit(.finished)
        #expect(terminalEvents == 1)
        #expect(first.stopCount > 0)
        #expect(second.stopCount > 0)
    }
}

@MainActor
private final class DiscoveryBackendFixture: TVDiscoveryBackend {
    private var eventHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?
    private(set) var stopCount = 0

    func start(eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ event: TVDiscoveryBackendEvent) {
        eventHandler?(event)
    }
}

/// Retains canceled producers deliberately; no network service or household data is used.
@MainActor
private final class HeldDiscoveryBackendFixture: TVDiscoveryBackend {
    private(set) var callbacks: [@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void] = []

    func start(eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void) {
        callbacks.append(eventHandler)
    }

    func stop() {}
}
