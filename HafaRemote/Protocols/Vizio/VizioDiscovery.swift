import CryptoKit
@preconcurrency import Foundation

/// Non-secret identity and presentation fields advertised by Vizio SmartCast.
struct VizioBonjourMetadata: Equatable, Sendable {
    let reportedIdentifier: String
    let displayName: String
    let modelName: String

    init(txtRecordData: Data?, serviceName: String) {
        let record = txtRecordData.map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        displayName = Self.cleaned(
            Self.value(for: "name", in: record) ?? serviceName,
            fallback: "Vizio TV",
            maximumLength: 80
        )
        modelName = Self.cleaned(
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
            reportedIdentifier =
                identifier.isEmpty
                ? Self.hashedIdentifier(for: serviceName) : identifier
        } else {
            // Some older SmartCast versions omit `did`. The hash is a
            // discovery-only identity; the HTTPS device-info response supplies
            // the durable serial identity before credentials are stored.
            reportedIdentifier = Self.hashedIdentifier(for: serviceName)
        }
    }

    private static func value(for key: String, in record: [String: Data]) -> String? {
        let data =
            record[key]
            ?? record.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
        guard let data, let value = String(data: data, encoding: .utf8) else {
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

    private static func hashedIdentifier(for serviceName: String) -> String {
        let digest = SHA256.hash(data: Data(serviceName.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol VizioServiceBrowserDelegate: AnyObject {
    func vizioServiceBrowserDidFind(_ service: NetService)
    func vizioServiceBrowserDidFail(errorCode: Int?)
}

@MainActor
protocol VizioServiceBrowsing: AnyObject {
    var delegate: (any VizioServiceBrowserDelegate)? { get set }
    func start()
    func stop()
}

/// Adapts Foundation's delegate API to the deterministic discovery boundary.
@MainActor
final class FoundationVizioServiceBrowser: NSObject, VizioServiceBrowsing {
    weak var delegate: (any VizioServiceBrowserDelegate)?
    private let browser = NetServiceBrowser()

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_viziocast._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
    }
}

extension FoundationVizioServiceBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        delegate?.vizioServiceBrowserDidFind(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        delegate?.vizioServiceBrowserDidFail(
            errorCode: errorDict[NetService.errorCode]?.intValue
        )
    }
}

/// Discovers Vizio SmartCast candidates. Selecting one still requires the
/// HTTPS device-info and PIN flow to verify and authorize the television.
@MainActor
final class VizioBonjourDiscoveryBackend: NSObject, TVDiscoveryBackend {
    static let policyDeniedErrorCode = -72_008

    typealias BrowserFactory = @MainActor () -> any VizioServiceBrowsing
    typealias ResolutionStarter = @MainActor (NetService, any NetServiceDelegate) -> Void
    typealias CandidateResolver = @MainActor (NetService) -> DiscoveredTV?

    private let makeBrowser: BrowserFactory
    private let startResolution: ResolutionStarter
    private let resolveCandidate: CandidateResolver
    private var browser: (any VizioServiceBrowsing)?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var eventHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?

    init(
        makeBrowser: @escaping BrowserFactory = { FoundationVizioServiceBrowser() },
        startResolution: @escaping ResolutionStarter = { service, delegate in
            service.delegate = delegate
            service.resolve(withTimeout: 5)
        },
        resolveCandidate: @escaping CandidateResolver = VizioBonjourDiscoveryBackend.candidate
    ) {
        self.makeBrowser = makeBrowser
        self.startResolution = startResolution
        self.resolveCandidate = resolveCandidate
    }

    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    ) {
        stop()
        self.eventHandler = eventHandler
        let browser = makeBrowser()
        browser.delegate = self
        self.browser = browser
        browser.start()
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

    func receiveResolvedService(_ service: NetService) {
        let serviceID = ObjectIdentifier(service)
        guard services[serviceID] != nil else { return }
        defer { services[serviceID] = nil }
        guard let candidate = resolveCandidate(service) else { return }
        eventHandler?(.found(candidate))
    }

    func receiveResolutionFailure(_ service: NetService) {
        services[ObjectIdentifier(service)] = nil
    }

    var trackedServiceCount: Int { services.count }

    private static func candidate(from service: NetService) -> DiscoveredTV? {
        guard let port = UInt16(exactly: service.port),
            VizioHTTPSClient.supports(controlPort: port),
            let address = SamsungBonjourDiscoveryBackend.privateIPv4Address(from: service)
        else {
            return nil
        }
        let metadata = VizioBonjourMetadata(
            txtRecordData: service.txtRecordData(),
            serviceName: service.name
        )
        return DiscoveredTV(
            brand: .vizio,
            reportedIdentifier: metadata.reportedIdentifier,
            displayName: metadata.displayName,
            modelName: metadata.modelName,
            address: address,
            controlPort: port
        )
    }
}

extension VizioBonjourDiscoveryBackend: VizioServiceBrowserDelegate {
    func vizioServiceBrowserDidFind(_ service: NetService) {
        services[ObjectIdentifier(service)] = service
        startResolution(service, self)
    }

    func vizioServiceBrowserDidFail(errorCode: Int?) {
        let handler = eventHandler
        stop()
        handler?(
            errorCode == Self.policyDeniedErrorCode ? .permissionDenied : .failed
        )
    }
}

extension VizioBonjourDiscoveryBackend: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        receiveResolvedService(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        receiveResolutionFailure(sender)
    }
}
