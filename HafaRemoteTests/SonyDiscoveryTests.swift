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
