import Foundation
import Testing

@testable import HafaRemote

struct VizioDiscoveryTests {
    @Test("Vizio TXT metadata produces a stable candidate with friendly presentation")
    func parsesVizioMetadata() throws {
        let txt = NetService.data(
            fromTXTRecord: [
                "did": Data("76F2C531-6BBE-4FCE-B907-B75231C47D35".utf8),
                "name": Data("Office TV".utf8),
                "mdl": Data("V655-G9".utf8),
            ]
        )

        let metadata = VizioBonjourMetadata(txtRecordData: txt, serviceName: "Fallback TV")

        #expect(metadata.reportedIdentifier == "76f2c531-6bbe-4fce-b907-b75231c47d35")
        #expect(metadata.displayName == "Office TV")
        #expect(metadata.modelName == "V655-G9")
    }

    @Test("Vizio discovery strips control characters and safely fills missing fields")
    func sanitizesVizioMetadata() throws {
        let txt = NetService.data(
            fromTXTRecord: [
                "did": Data("candidate-1".utf8),
                "name": Data("\u{0000}Living Room\n".utf8),
            ]
        )

        let metadata = VizioBonjourMetadata(txtRecordData: txt, serviceName: "Fallback TV")

        #expect(metadata.displayName == "Living Room")
        #expect(metadata.modelName == "Vizio SmartCast")
    }

    @Test("A missing advertised ID receives a stable discovery-only identity")
    func hashesServiceNameWhenIdentifierIsMissing() throws {
        let txt = NetService.data(fromTXTRecord: ["name": Data("Office TV".utf8)])

        let first = VizioBonjourMetadata(txtRecordData: txt, serviceName: "Office TV")
        let second = VizioBonjourMetadata(txtRecordData: txt, serviceName: "Office TV")

        #expect(first.reportedIdentifier == second.reportedIdentifier)
        #expect(first.reportedIdentifier.count == 64)
    }

    @Test("Missing TXT data uses fixed safe fallbacks")
    func acceptsMissingTXTData() {
        let metadata = VizioBonjourMetadata(txtRecordData: nil, serviceName: "Office TV")

        #expect(
            metadata.reportedIdentifier
                == "a1b3884bcfd2b47b116f7558d63856956559ced117f296d76885d3e31d10ee7d"
        )
        #expect(metadata.displayName == "Office TV")
        #expect(metadata.modelName == "Vizio SmartCast")
    }

    @Test("DNS-SD keys are matched without case sensitivity")
    func acceptsUppercaseTXTKeys() {
        let txt = NetService.data(
            fromTXTRecord: [
                "DID": Data("UPPER-ID".utf8),
                "NAME": Data("Family Room".utf8),
                "MDL": Data("V505-H9".utf8),
            ]
        )

        let metadata = VizioBonjourMetadata(txtRecordData: txt, serviceName: "Fallback TV")

        #expect(metadata.reportedIdentifier == "upper-id")
        #expect(metadata.displayName == "Family Room")
        #expect(metadata.modelName == "V505-H9")
    }

    @Test("Only documented SmartCast HTTPS ports become control candidates")
    func validatesControlPorts() {
        #expect(VizioHTTPSClient.supports(controlPort: 7345))
        #expect(VizioHTTPSClient.supports(controlPort: 9000))
        #expect(!VizioHTTPSClient.supports(controlPort: 443))
    }

    @MainActor
    @Test("A resolved service publishes once and releases its resolution state")
    func publishesResolvedService() throws {
        let browser = FakeVizioServiceBrowser()
        let recorder = VizioDiscoveryEventRecorder()
        let candidate = try fixtureCandidate()
        let backend = VizioBonjourDiscoveryBackend(
            makeBrowser: { browser },
            startResolution: { _, _ in },
            resolveCandidate: { _ in candidate }
        )
        let service = fixtureService()

        backend.start { recorder.receive($0) }
        browser.emitFound(service)
        #expect(browser.startCount == 1)
        #expect(backend.trackedServiceCount == 1)

        backend.receiveResolvedService(service)
        #expect(recorder.found == [candidate])
        #expect(backend.trackedServiceCount == 0)

        backend.receiveResolvedService(service)
        #expect(recorder.found == [candidate])
    }

    @MainActor
    @Test("Resolution failure and stop discard late service callbacks")
    func discardsFailedAndCancelledResolution() throws {
        let browser = FakeVizioServiceBrowser()
        let recorder = VizioDiscoveryEventRecorder()
        let candidate = try fixtureCandidate()
        let backend = VizioBonjourDiscoveryBackend(
            makeBrowser: { browser },
            startResolution: { _, _ in },
            resolveCandidate: { _ in candidate }
        )
        let failedService = fixtureService(name: "Failed TV")
        let stoppedService = fixtureService(name: "Stopped TV")

        backend.start { recorder.receive($0) }
        browser.emitFound(failedService)
        backend.receiveResolutionFailure(failedService)
        backend.receiveResolvedService(failedService)
        #expect(backend.trackedServiceCount == 0)
        #expect(recorder.found.isEmpty)

        browser.emitFound(stoppedService)
        backend.stop()
        backend.receiveResolvedService(stoppedService)
        #expect(browser.stopCount == 1)
        #expect(backend.trackedServiceCount == 0)
        #expect(recorder.found.isEmpty)
    }

    @MainActor
    @Test("Browser failures map safely and a later start can recover")
    func mapsFailureAndRecovers() throws {
        let firstBrowser = FakeVizioServiceBrowser()
        let secondBrowser = FakeVizioServiceBrowser()
        let browsers = [firstBrowser, secondBrowser]
        var browserIndex = 0
        let recorder = VizioDiscoveryEventRecorder()
        let candidate = try fixtureCandidate()
        let backend = VizioBonjourDiscoveryBackend(
            makeBrowser: {
                defer { browserIndex += 1 }
                return browsers[browserIndex]
            },
            startResolution: { _, _ in },
            resolveCandidate: { _ in candidate }
        )

        backend.start { recorder.receive($0) }
        firstBrowser.emitFailure(code: 1)
        #expect(recorder.failedCount == 1)
        #expect(firstBrowser.stopCount == 1)

        backend.start { recorder.receive($0) }
        let service = fixtureService()
        secondBrowser.emitFound(service)
        backend.receiveResolvedService(service)
        #expect(secondBrowser.startCount == 1)
        #expect(recorder.found == [candidate])
    }

    @MainActor
    @Test("Local Network policy denial has a distinct event")
    func mapsPolicyDenial() {
        let browser = FakeVizioServiceBrowser()
        let recorder = VizioDiscoveryEventRecorder()
        let backend = VizioBonjourDiscoveryBackend(
            makeBrowser: { browser },
            startResolution: { _, _ in },
            resolveCandidate: { _ in nil }
        )

        backend.start { recorder.receive($0) }
        browser.emitFailure(code: VizioBonjourDiscoveryBackend.policyDeniedErrorCode)

        #expect(recorder.permissionDeniedCount == 1)
        #expect(recorder.failedCount == 0)
    }

    private func fixtureCandidate() throws -> DiscoveredTV {
        DiscoveredTV(
            brand: .vizio,
            reportedIdentifier: "synthetic-vizio",
            displayName: "Office TV",
            modelName: "V655-G9",
            address: try PrivateIPv4Address("192.168.10.20"),
            controlPort: 7345
        )
    }

    private func fixtureService(name: String = "Office TV") -> NetService {
        NetService(
            domain: "local.",
            type: "_viziocast._tcp.",
            name: name,
            port: 7345
        )
    }
}

@MainActor
private final class FakeVizioServiceBrowser: VizioServiceBrowsing {
    weak var delegate: (any VizioServiceBrowserDelegate)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emitFound(_ service: NetService) {
        delegate?.vizioServiceBrowserDidFind(service)
    }

    func emitFailure(code: Int?) {
        delegate?.vizioServiceBrowserDidFail(errorCode: code)
    }
}

@MainActor
private final class VizioDiscoveryEventRecorder {
    private(set) var found: [DiscoveredTV] = []
    private(set) var permissionDeniedCount = 0
    private(set) var failedCount = 0

    func receive(_ event: TVDiscoveryBackendEvent) {
        switch event {
        case .found(let television):
            found.append(television)
        case .permissionDenied:
            permissionDeniedCount += 1
        case .failed:
            failedCount += 1
        case .finished:
            break
        }
    }
}
