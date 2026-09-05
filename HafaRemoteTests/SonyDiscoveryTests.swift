import Foundation
import Testing

@testable import HafaRemote

struct SonyDiscoveryTests {
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
