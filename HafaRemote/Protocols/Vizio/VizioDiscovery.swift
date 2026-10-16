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
    func vizioServiceBrowser(_ browser: any VizioServiceBrowsing, didFind service: NetService)
    func vizioServiceBrowser(_ browser: any VizioServiceBrowsing, didFail errorCode: Int?)
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
        delegate?.vizioServiceBrowser(self, didFind: service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        delegate?.vizioServiceBrowser(
            self, didFail: errorDict[NetService.errorCode]?.intValue
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
    private var resolutionAttempts: [ObjectIdentifier: Int] = [:]
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
        eventHandler(.progress(TVDiscoveryProgress(brand: .vizio, stage: .browsing)))
        guard self.browser === browser else { return }
        browser.start()
    }

    func stop() {
        let oldBrowser = browser
        let oldServices = Array(services.values)
        browser = nil
        services.removeAll()
        resolutionAttempts.removeAll()
        eventHandler = nil
        oldBrowser?.delegate = nil
        oldBrowser?.stop()
        for service in oldServices {
            service.delegate = nil
            service.stop()
        }
    }

    func receiveResolvedService(_ service: NetService) {
        let serviceID = ObjectIdentifier(service)
        guard services[serviceID] === service else { return }
        defer {
            services[serviceID] = nil
            resolutionAttempts[serviceID] = nil
        }
        eventHandler?(.progress(TVDiscoveryProgress(brand: .vizio, stage: .resolved)))
        guard services[serviceID] === service else { return }
        guard let candidate = resolveCandidate(service) else {
            eventHandler?(.progress(TVDiscoveryProgress(brand: .vizio, stage: .endpointRejected)))
            return
        }
        eventHandler?(.found(candidate))
    }

    func receiveResolutionFailure(_ service: NetService) {
        let serviceID = ObjectIdentifier(service)
        guard services[serviceID] === service else { return }
        eventHandler?(.progress(TVDiscoveryProgress(brand: .vizio, stage: .resolutionFailed)))
        guard services[serviceID] === service else { return }
        if resolutionAttempts[serviceID] == 1 {
            services[serviceID] = nil
            resolutionAttempts[serviceID] = nil
            service.stop()
            service.delegate = nil
            // A fresh producer prevents late callbacks from the failed attempt
            // from being accepted as the retry's result.
            let retry = NetService(domain: service.domain, type: service.type, name: service.name)
            let retryID = ObjectIdentifier(retry)
            services[retryID] = retry
            resolutionAttempts[retryID] = 2
            eventHandler?(.progress(TVDiscoveryProgress(brand: .vizio, stage: .resolutionRetrying)))
            guard services[retryID] === retry else { return }
            startResolution(retry, self)
        } else {
            services[serviceID] = nil
            resolutionAttempts[serviceID] = nil
        }
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
    func vizioServiceBrowser(_ browser: any VizioServiceBrowsing, didFind service: NetService) {
        guard self.browser === browser else { return }
        services[ObjectIdentifier(service)] = service
        resolutionAttempts[ObjectIdentifier(service)] = 1
        eventHandler?(.progress(TVDiscoveryProgress(brand: .vizio, stage: .advertised)))
        guard self.browser === browser, services[ObjectIdentifier(service)] === service else { return }
        startResolution(service, self)
    }

    func vizioServiceBrowser(_ browser: any VizioServiceBrowsing, didFail errorCode: Int?) {
        guard self.browser === browser else { return }
        let handler = eventHandler
        stop()
        handler?(
            .progress(
                TVDiscoveryProgress(
                    brand: .vizio,
                    stage: errorCode == Self.policyDeniedErrorCode ? .permissionDenied : .browserFailed)))
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
