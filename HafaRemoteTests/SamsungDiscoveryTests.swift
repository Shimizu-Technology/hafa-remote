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

    /// Discovery keeps a room-friendly name while merging endpoint advertisements.
    @Test("A discovery target carries its room-friendly TV name into pairing")
    func preservesDiscoveredDisplayName() throws {
        let television = DiscoveredTV(
            reportedIdentifier: "synthetic-tv",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: try PrivateIPv4Address("192.168.10.20")
        )

        #expect(television.connectionTarget.suggestedDisplayName == "Living Room TV")
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
        let first = DiscoveredTV(
            reportedIdentifier: "same-tv",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: try PrivateIPv4Address("192.168.10.20")
        )
        let moved = DiscoveredTV(
            reportedIdentifier: "same-tv",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: try PrivateIPv4Address("192.168.10.21")
        )
        let backend = DiscoveryBackendSpy(events: [.found(first), .found(moved), .finished])
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.state == .results)
        #expect(store.televisions == [moved])
        #expect(backend.startCount == 1)
        #expect(backend.stopCount >= 1)
    }

    @MainActor
    @Test("Discovery keeps identical reported identifiers from different brands separate")
    func scopesReportedIdentityByBrand() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let samsung = DiscoveredTV(
            brand: .samsung,
            reportedIdentifier: "shared-identifier",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: address
        )
        let sony = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "shared-identifier",
            displayName: "Living Room TV",
            modelName: "Sony Bravia",
            address: address,
            controlPort: 6466
        )
        let backend = DiscoveryBackendSpy(
            events: [.found(sony), .found(samsung), .finished]
        )
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.televisions.count == 2)
        #expect(Set(store.televisions.map(\.id)) == ["samsung:shared-identifier", "sony:shared-identifier"])
        #expect(store.televisions.map(\.brand) == [.samsung, .sony])
        #expect(sony.controlPort == 6466)
    }

    @MainActor
    @Test("Discovery collapses duplicate service names for one brand endpoint")
    func deduplicatesByBrandEndpointAndKeepsTheFriendlierName() throws {
        let address = try PrivateIPv4Address("192.168.10.30")
        let modelAdvertisement = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-model-advertisement",
            displayName: "XBR-55X700D",
            modelName: "Google TV",
            address: address,
            controlPort: 6466
        )
        let roomAdvertisement = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-room-advertisement",
            displayName: "Side Door TV",
            modelName: "Google TV",
            address: address,
            controlPort: 6466
        )
        let backend = DiscoveryBackendSpy(
            events: [.found(modelAdvertisement), .found(roomAdvertisement), .finished]
        )
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.televisions.count == 1)
        #expect(store.televisions[0].reportedIdentifier == modelAdvertisement.reportedIdentifier)
        #expect(store.televisions[0].displayName == roomAdvertisement.displayName)
        #expect(
            store.televisions[0].connectionTarget
                == TVConnectionTarget(
                    brand: modelAdvertisement.brand,
                    reportedDeviceID: modelAdvertisement.reportedIdentifier,
                    address: modelAdvertisement.address,
                    controlPort: modelAdvertisement.controlPort,
                    suggestedDisplayName: roomAdvertisement.displayName
                )
        )
    }

    @MainActor
    @Test("Discovery does not replace a room name with a generic TV label")
    func keepsRoomNameOverGenericLabel() throws {
        let address = try PrivateIPv4Address("192.168.10.30")
        let roomAdvertisement = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-room-advertisement",
            displayName: "Living Room",
            modelName: "Google TV",
            address: address,
            controlPort: 6466
        )
        let genericAdvertisement = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-generic-advertisement",
            displayName: "TV",
            modelName: "Google TV",
            address: address,
            controlPort: 6466
        )
        let backend = DiscoveryBackendSpy(
            events: [.found(roomAdvertisement), .found(genericAdvertisement), .finished]
        )
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.televisions == [roomAdvertisement])
    }

    @MainActor
    @Test("Discovery keeps different brands at the same endpoint separate")
    func keepsSameEndpointAcrossBrandsSeparate() throws {
        let address = try PrivateIPv4Address("192.168.10.30")
        let sony = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-shared-endpoint",
            displayName: "Living Room Sony",
            modelName: "Google TV",
            address: address,
            controlPort: 6466
        )
        let vizio = DiscoveredTV(
            brand: .vizio,
            reportedIdentifier: "vizio-shared-endpoint",
            displayName: "Living Room Vizio",
            modelName: "SmartCast",
            address: address,
            controlPort: 6466
        )
        let backend = DiscoveryBackendSpy(events: [.found(sony), .found(vizio), .finished])
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.televisions == [sony, vizio])
    }

    @MainActor
    @Test("Discovery keeps same-brand services on different control ports separate")
    func keepsDifferentControlEndpointsSeparate() throws {
        let address = try PrivateIPv4Address("192.168.10.30")
        let first = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-remote-service",
            displayName: "Side Door TV",
            modelName: "Google TV",
            address: address,
            controlPort: 6466
        )
        let second = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-other-service",
            displayName: "Side Door TV",
            modelName: "Google TV",
            address: address,
            controlPort: 6467
        )
        let backend = DiscoveryBackendSpy(events: [.found(first), .found(second), .finished])
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.televisions == [first, second])
    }

    @MainActor
    @Test("Discovery removes an old identity endpoint when it moves onto an existing endpoint")
    func deduplicatesIdentityMovingOntoExistingEndpoint() throws {
        let firstAddress = try PrivateIPv4Address("192.168.10.30")
        let secondAddress = try PrivateIPv4Address("192.168.10.31")
        let original = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-moving-service",
            displayName: "Bedroom TV",
            modelName: "Google TV",
            address: firstAddress,
            controlPort: 6466
        )
        let existingEndpoint = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "sony-existing-service",
            displayName: "TV",
            modelName: "Google TV",
            address: secondAddress,
            controlPort: 6466
        )
        let moved = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: original.reportedIdentifier,
            displayName: "Living Room TV",
            modelName: "Google TV",
            address: secondAddress,
            controlPort: 6466
        )
        let backend = DiscoveryBackendSpy(
            events: [.found(original), .found(existingEndpoint), .found(moved), .finished]
        )
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.televisions.count == 1)
        #expect(store.televisions[0].reportedIdentifier == existingEndpoint.reportedIdentifier)
        #expect(store.televisions[0].displayName == moved.displayName)
        #expect(
            store.televisions[0].connectionTarget
                == TVConnectionTarget(
                    brand: existingEndpoint.brand,
                    reportedDeviceID: existingEndpoint.reportedIdentifier,
                    address: existingEndpoint.address,
                    controlPort: existingEndpoint.controlPort,
                    suggestedDisplayName: moved.displayName
                )
        )
    }

    @MainActor
    @Test("A completed search with no verified TVs has a useful empty state")
    func representsNoResults() {
        let backend = DiscoveryBackendSpy(events: [.finished])
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        store.start()

        #expect(store.state == .noResults)
        #expect(store.televisions.isEmpty)
    }

    @MainActor
    @Test("A saved TV is resolved by stable identity after its IP address changes")
    func resolvesSavedIdentityAtNewAddress() async throws {
        let moved = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: "saved-sony",
            displayName: "Bedroom TV",
            modelName: "Sony BRAVIA",
            address: try PrivateIPv4Address("192.168.10.91"),
            controlPort: 6466
        )
        let backend = DiscoveryBackendSpy(events: [.found(moved), .finished])
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        let target = await store.findDevice(stableDeviceKey: "sony:saved-sony")

        #expect(target == moved.connectionTarget)
        #expect(backend.startCount == 1)
    }

    @MainActor
    @Test("Saved-TV resolution ignores a different TV on the same network")
    func doesNotResolveDifferentIdentity() async throws {
        let other = DiscoveredTV(
            reportedIdentifier: "different-tv",
            displayName: "Other TV",
            modelName: "Samsung TV",
            address: try PrivateIPv4Address("192.168.10.92")
        )
        let backend = DiscoveryBackendSpy(events: [.found(other), .finished])
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

        let target = await store.findDevice(stableDeviceKey: "samsung:saved-tv")

        #expect(target == nil)
    }

    @MainActor
    @Test("Local-network policy denial remains distinct from a generic discovery failure")
    func representsPermissionDenial() async {
        let backend = DiscoveryBackendSpy(events: [.permissionDenied])
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(10))

        store.start()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(store.state == .permissionDenied)
        #expect(store.televisions.isEmpty)
    }

    @MainActor
    @Test("A failed search can recover to verified results")
    func recoversFromFailure() throws {
        let television = DiscoveredTV(
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
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))

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
        let store = TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(10))

        store.start()
        store.stop()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(backend.stopCount >= 2)
        #expect(store.state == .idle)
        #expect(store.televisions.isEmpty)
    }

    @Test("A discovered TV never describes its network address")
    func redactsAddressInDescriptions() throws {
        let television = DiscoveredTV(
            reportedIdentifier: "same-tv",
            displayName: "Living Room TV",
            modelName: "Samsung Q70A",
            address: try PrivateIPv4Address("192.168.10.20")
        )

        #expect(television.description == "DiscoveredTV(redacted)")
        #expect(!television.description.contains(television.address.rawValue))
        #expect(!television.debugDescription.contains(television.address.rawValue))
    }
}

@MainActor
private final class DiscoveryBackendSpy: TVDiscoveryBackend {
    private let events: [TVDiscoveryBackendEvent]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(events: [TVDiscoveryBackendEvent]) {
        self.events = events
    }

    deinit {}

    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    ) {
        startCount += 1
        events.forEach(eventHandler)
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class SequencedDiscoveryBackend: TVDiscoveryBackend {
    private var eventSequences: [[TVDiscoveryBackendEvent]]
    private(set) var startCount = 0

    init(eventSequences: [[TVDiscoveryBackendEvent]]) {
        self.eventSequences = eventSequences
    }

    deinit {}

    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    ) {
        startCount += 1
        guard !eventSequences.isEmpty else { return }
        eventSequences.removeFirst().forEach(eventHandler)
    }

    func stop() {}
}
