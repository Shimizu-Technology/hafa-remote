import CryptoKit
@preconcurrency import Foundation

/// Non-secret identity and presentation fields advertised by Vizio SmartCast.
struct VizioBonjourMetadata: Equatable, Sendable {
    let reportedIdentifier: String
    let displayName: String
    let modelName: String

    init?(txtRecordData: Data?, serviceName: String) {
        guard let txtRecordData else { return nil }
        let record = NetService.dictionary(fromTXTRecord: txtRecordData)
        let displayName = Self.cleaned(
            Self.value(for: "name", in: record) ?? serviceName,
            fallback: "Vizio TV",
            maximumLength: 80
        )
        let modelName = Self.cleaned(
            Self.value(for: "mdl", in: record) ?? "Vizio SmartCast",
            fallback: "Vizio SmartCast",
            maximumLength: 80
        )

        if let advertisedIdentifier = Self.value(for: "did", in: record) {
            let identifier = Self.cleaned(
                advertisedIdentifier.lowercased(),
                fallback: "",
                maximumLength: 512
            )
            guard !identifier.isEmpty else { return nil }
            reportedIdentifier = identifier
        } else {
            // Some older SmartCast versions omit `did`. The hash is a
            // discovery-only identity; the HTTPS device-info response supplies
            // the durable serial identity before credentials are stored.
            let digest = SHA256.hash(data: Data(serviceName.utf8))
            reportedIdentifier = digest.map { String(format: "%02x", $0) }.joined()
        }

        self.displayName = displayName
        self.modelName = modelName
    }

    private static func value(for key: String, in record: [String: Data]) -> String? {
        guard let data = record[key], let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let cleanedValue = cleaned(value, fallback: "", maximumLength: 512)
        return cleanedValue.isEmpty ? nil : cleanedValue
    }

    private static func cleaned(
        _ value: String,
        fallback: String,
        maximumLength: Int
    ) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let trimmed = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(maximumLength))
    }
}

/// Discovers Vizio SmartCast candidates. Selecting one still requires the
/// HTTPS device-info and PIN flow to verify and authorize the television.
@MainActor
final class VizioBonjourDiscoveryBackend: NSObject, TVDiscoveryBackend {
    private static let serviceType = "_viziocast._tcp."
    private static let policyDeniedErrorCode = -72_008

    private var browser: NetServiceBrowser?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var eventHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?

    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    ) {
        stop()
        self.eventHandler = eventHandler
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }

    func stop() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in services.values {
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
        eventHandler = nil
    }

    private func publish(_ service: NetService) {
        defer { services[ObjectIdentifier(service)] = nil }
        guard let port = UInt16(exactly: service.port),
            VizioHTTPSClient.supports(controlPort: port),
            let metadata = VizioBonjourMetadata(
                txtRecordData: service.txtRecordData(),
                serviceName: service.name
            ),
            let address = SamsungBonjourDiscoveryBackend.privateIPv4Address(from: service)
        else {
            return
        }

        eventHandler?(
            .found(
                DiscoveredTV(
                    brand: .vizio,
                    reportedIdentifier: metadata.reportedIdentifier,
                    displayName: metadata.displayName,
                    modelName: metadata.modelName,
                    address: address,
                    controlPort: port
                )
            )
        )
    }
}

extension VizioBonjourDiscoveryBackend: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        services[ObjectIdentifier(service)] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let handler = eventHandler
        let code = errorDict[NetService.errorCode]?.intValue
        stop()
        handler?(code == Self.policyDeniedErrorCode ? .permissionDenied : .failed)
    }
}

extension VizioBonjourDiscoveryBackend: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        publish(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        services[ObjectIdentifier(sender)] = nil
    }
}
