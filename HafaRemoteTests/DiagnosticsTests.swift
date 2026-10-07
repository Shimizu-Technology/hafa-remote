import Foundation
import Testing

@testable import HafaRemote

@MainActor
struct DiagnosticsTests {
    @Test("Diagnostic metadata omits a protocol display name used as Sony model fallback")
    func modelFallbackCannotExportTVName() throws {
        let television = ConnectedTV(
            brand: .sony, reportedDeviceID: "synthetic-sony-tv",
            address: try PrivateIPv4Address(documentationAddressForTesting: "198.51.100.46"),
            displayName: "Synthetic Room Name", modelName: "Synthetic Room Name", firmwareVersion: nil
        )
        let metadata = DiagnosticMetadata.current(verifiedTV: television)
        #expect(metadata.tvModel == "Not included")
        #expect(!DiagnosticReport(metadata: metadata, events: []).text.contains("Synthetic Room Name"))
    }

    @Test("Diagnostics are opt-in, bounded, and cleared when disabled")
    func boundedOptInCollection() {
        let recorder = DiagnosticRecorder()
        recorder.record(.pairingStarted)
        #expect(recorder.events.isEmpty)
        recorder.setEnabled(true)
        recorder.record(.pairingApproved)
        for _ in 0..<DiagnosticRecorder.maximumEventCount {
            recorder.record(.connectionReady, durationSeconds: 2)
        }
        #expect(recorder.events.count == 100)
        #expect(recorder.events.allSatisfy { $0.kind == .connectionReady })
        recorder.setEnabled(false)
        #expect(recorder.events.isEmpty)
        recorder.setEnabled(true)
        #expect(recorder.events.isEmpty)
    }

    @Test("Timing is coarse and invalid values are never exported")
    func timingBuckets() {
        #expect(DiagnosticDuration(seconds: 0.999) == .underOneSecond)
        #expect(DiagnosticDuration(seconds: 1) == .oneToThreeSeconds)
        #expect(DiagnosticDuration(seconds: 3) == .threeToTenSeconds)
        #expect(DiagnosticDuration(seconds: 10) == .tenSecondsOrMore)
        #expect(DiagnosticDuration(seconds: nil) == .unknown)
        #expect(DiagnosticDuration(seconds: -.infinity) == .unknown)
        #expect(DiagnosticDuration(seconds: .nan) == .unknown)
        #expect(DiagnosticDuration(seconds: -1) == .unknown)
    }

    @Test("Reports include only approved metadata and semantic events")
    func privacySafeReport() {
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        recorder.record(.commandDeliveryFailed, durationSeconds: 2.125)
        let report = recorder.report(
            metadata: DiagnosticMetadata(
                appVersion: "1.1", appBuild: "22", iOSVersion: "26.0",
                tvModel: "Synthetic Model", tvFirmware: "1.2.3"
            ))
        #expect(report.text.contains("Synthetic Model"))
        #expect(report.text.contains("1.2.3"))
        #expect(report.text.contains("Command delivery failed (1–3 seconds)"))
        #expect(!report.text.contains("2.125"))
        #expect(!report.text.contains("Optional("))
    }

    @Test(
        "Network identifiers and secret-shaped metadata are rejected",
        arguments: [
            "192.0.2.20", "198.51.100.10", "203.0.113.5", "02:00:5E:00:53:01",
            "02-00-5E-00-53-01", "https://example.test", "synthetic@example.test",
            "00000000-0000-0000-0000-000000000001", String(repeating: "a", count: 64),
            "token synthetic", "serial synthetic", "line\nsecret", String(repeating: "x", count: 81),
        ])
    func metadataExcludesIdentifiers(_ sensitive: String) {
        let metadata = DiagnosticMetadata(
            appVersion: sensitive, appBuild: sensitive, iOSVersion: sensitive,
            tvModel: sensitive, tvFirmware: sensitive
        )
        #expect(metadata.appVersion == "Not included")
        #expect(metadata.appBuild == "Not included")
        #expect(metadata.iOSVersion == "Not included")
        #expect(metadata.tvModel == "Not included")
        #expect(metadata.tvFirmware == "Not included")
        #expect(!DiagnosticReport(metadata: metadata, events: []).text.contains(sensitive))
    }

    @Test("The shared preview remains an immutable snapshot")
    func immutableSnapshot() {
        let recorder = DiagnosticRecorder()
        recorder.setEnabled(true)
        recorder.record(.discoveryStarted)
        let snapshot = recorder.report(
            metadata: DiagnosticMetadata(
                appVersion: "1", appBuild: "1", iOSVersion: "26"
            ))
        recorder.record(.discoveryFinished)
        recorder.clear()
        #expect(snapshot.events.map(\.kind) == [.discoveryStarted])
        #expect(!snapshot.text.contains("Discovery finished"))
    }
}
