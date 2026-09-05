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

        let metadata = try #require(
            VizioBonjourMetadata(txtRecordData: txt, serviceName: "Fallback TV")
        )

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

        let metadata = try #require(
            VizioBonjourMetadata(txtRecordData: txt, serviceName: "Fallback TV")
        )

        #expect(metadata.displayName == "Living Room")
        #expect(metadata.modelName == "Vizio SmartCast")
    }

    @Test("A missing advertised ID receives a stable discovery-only identity")
    func hashesServiceNameWhenIdentifierIsMissing() throws {
        let txt = NetService.data(fromTXTRecord: ["name": Data("Office TV".utf8)])

        let first = try #require(
            VizioBonjourMetadata(txtRecordData: txt, serviceName: "Office TV")
        )
        let second = try #require(
            VizioBonjourMetadata(txtRecordData: txt, serviceName: "Office TV")
        )

        #expect(first.reportedIdentifier == second.reportedIdentifier)
        #expect(first.reportedIdentifier.count == 64)
    }

    @Test("Only documented SmartCast HTTPS ports become control candidates")
    func validatesControlPorts() {
        #expect(VizioHTTPSClient.supports(controlPort: 7345))
        #expect(VizioHTTPSClient.supports(controlPort: 9000))
        #expect(!VizioHTTPSClient.supports(controlPort: 443))
    }
}
