import Foundation
import Testing

@testable import HafaRemote

struct SamsungDiscoveryTests {
    @Test("Samsung Bonjour metadata uses the reported device ID, name, and model")
    func parsesBonjourMetadata() throws {
        let txtData = NetService.data(fromTXTRecord: [
            "id": Data("SYNTHETIC-ID".utf8),
            "fn": Data("  Living Room TV  ".utf8),
            "md": Data("Samsung Q70A".utf8),
        ])

        let metadata = try #require(
            SamsungBonjourMetadata(txtRecordData: txtData, serviceName: "Fallback TV")
        )

        #expect(metadata.reportedIdentifier == "synthetic-id")
        #expect(metadata.displayName == "Living Room TV")
        #expect(metadata.advertisedModelName == "Samsung Q70A")
    }

    @Test("Bonjour records without a stable reported device ID are ignored")
    func rejectsBonjourMetadataWithoutIdentity() {
        let txtData = NetService.data(fromTXTRecord: [
            "fn": Data("Unidentified TV".utf8)
        ])

        #expect(SamsungBonjourMetadata(txtRecordData: txtData, serviceName: "TV") == nil)
    }

    @MainActor
    @Test("Discovery deduplicates a TV by reported identity when its address changes")
    func deduplicatesByReportedIdentity() throws {
        let first = DiscoveredSamsungTV(
            reportedIdentifier: "same-tv",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: try PrivateIPv4Address("192.168.10.20")
        )
        let moved = DiscoveredSamsungTV(
            reportedIdentifier: "same-tv",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: try PrivateIPv4Address("192.168.10.21")
        )
        let backend = DiscoveryBackendSpy(events: [.found(first), .found(moved), .finished])
        let store = SamsungDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.state == .results)
        #expect(store.televisions == [moved])
        #expect(backend.startCount == 1)
        #expect(backend.stopCount >= 1)
    }

    @MainActor
    @Test("A completed search with no verified TVs has a useful empty state")
    func representsNoResults() {
        let backend = DiscoveryBackendSpy(events: [.finished])
        let store = SamsungDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.state == .noResults)
        #expect(store.televisions.isEmpty)
    }

    @MainActor
    @Test("Local-network policy denial remains distinct from a generic discovery failure")
    func representsPermissionDenial() async {
        let backend = DiscoveryBackendSpy(events: [.permissionDenied])
        let store = SamsungDiscoveryStore(backend: backend, searchDuration: .milliseconds(10))

        store.start()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(store.state == .permissionDenied)
        #expect(store.televisions.isEmpty)
    }

    @MainActor
    @Test("A failed search can recover to verified results")
    func recoversFromFailure() throws {
        let television = DiscoveredSamsungTV(
            reportedIdentifier: "recovered-tv",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: try PrivateIPv4Address("192.168.10.20")
        )
        let backend = SequencedDiscoveryBackend(
            eventSequences: [
                [.failed],
                [.found(television), .finished],
            ]
        )
        let store = SamsungDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()
        #expect(store.state == .failed)

        store.start()
        #expect(store.state == .results)
        #expect(store.televisions == [television])
        #expect(backend.startCount == 2)
    }

    @MainActor
    @Test("Stopping discovery cancels its backend and timeout")
    func stopCancelsSearch() async {
        let backend = DiscoveryBackendSpy(events: [])
        let store = SamsungDiscoveryStore(backend: backend, searchDuration: .milliseconds(10))

        store.start()
        store.stop()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(backend.stopCount >= 2)
        #expect(store.state == .idle)
        #expect(store.televisions.isEmpty)
    }

    @Test("A discovered TV never describes its network address")
    func redactsAddressInDescriptions() throws {
        let television = DiscoveredSamsungTV(
            reportedIdentifier: "same-tv",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: try PrivateIPv4Address("192.168.10.20")
        )

        #expect(television.description == "DiscoveredSamsungTV(redacted)")
        #expect(!television.description.contains(television.address.rawValue))
        #expect(!television.debugDescription.contains(television.address.rawValue))
    }
}

@MainActor
private final class DiscoveryBackendSpy: SamsungDiscoveryBackend {
    private let events: [SamsungDiscoveryBackendEvent]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(events: [SamsungDiscoveryBackendEvent]) {
        self.events = events
    }

    deinit {}

    func start(
        eventHandler: @escaping @MainActor @Sendable (SamsungDiscoveryBackendEvent) -> Void
    ) {
        startCount += 1
        events.forEach(eventHandler)
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class SequencedDiscoveryBackend: SamsungDiscoveryBackend {
    private var eventSequences: [[SamsungDiscoveryBackendEvent]]
    private(set) var startCount = 0

    init(eventSequences: [[SamsungDiscoveryBackendEvent]]) {
        self.eventSequences = eventSequences
    }

    deinit {}

    func start(
        eventHandler: @escaping @MainActor @Sendable (SamsungDiscoveryBackendEvent) -> Void
    ) {
        startCount += 1
        guard !eventSequences.isEmpty else { return }
        eventSequences.removeFirst().forEach(eventHandler)
    }

    func stop() {}
}
