@preconcurrency import Foundation
import Observation

/// A nearby TV candidate validated by its brand-specific discovery backend.
struct DiscoveredTV: Identifiable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let brand: TVBrand
    let reportedIdentifier: String
    let displayName: String
    let modelName: String
    let address: PrivateIPv4Address
    let controlPort: UInt16?

    init(
        brand: TVBrand = .samsung,
        reportedIdentifier: String,
        displayName: String,
        modelName: String,
        address: PrivateIPv4Address,
        controlPort: UInt16? = nil
    ) {
        self.brand = brand
        self.reportedIdentifier = reportedIdentifier
        self.displayName = displayName
        self.modelName = modelName
        self.address = address
        self.controlPort = controlPort
    }

    var id: String { "\(brand.rawValue):\(reportedIdentifier)" }

    var connectionTarget: TVConnectionTarget {
        TVConnectionTarget(
            brand: brand,
            reportedDeviceID: reportedIdentifier,
            address: address,
            controlPort: controlPort
        )
    }

    var description: String { "DiscoveredTV(redacted)" }
    var debugDescription: String { description }
}

enum TVDiscoveryState: Equatable, Sendable {
    case idle
    case searching
    case results
    case noResults
    case permissionDenied
    case failed
}

enum TVDiscoveryBackendEvent: Sendable {
    case found(DiscoveredTV)
    case finished
    case permissionDenied
    case failed
}

@MainActor
protocol TVDiscoveryBackend: AnyObject {
    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    )
    func stop()
}

/// Owns the user-visible discovery lifecycle and brand-scoped result set.
@MainActor
@Observable
final class TVDiscoveryStore {
    private(set) var state: TVDiscoveryState = .idle
    private(set) var televisions: [DiscoveredTV] = []

    @ObservationIgnored private let backend: any TVDiscoveryBackend
    @ObservationIgnored private let searchDuration: Duration
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    init(
        backend: (any TVDiscoveryBackend)? = nil,
        searchDuration: Duration = .seconds(8)
    ) {
        self.backend = backend ?? SamsungBonjourDiscoveryBackend()
        self.searchDuration = searchDuration
    }

    func start() {
        stop(resetState: false)
        televisions = []
        state = .searching

        timeoutTask = Task { [weak self, searchDuration] in
            do {
                try await Task.sleep(for: searchDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finishSearch()
        }

        backend.start { [weak self] event in
            self?.receive(event)
        }
    }

    func stop() {
        stop(resetState: true)
    }

    private func stop(resetState: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        backend.stop()
        if resetState, state == .searching {
            state = televisions.isEmpty ? .idle : .results
        }
    }

    private func receive(_ event: TVDiscoveryBackendEvent) {
        guard state == .searching || state == .results else { return }

        switch event {
        case .found(let television):
            if let index = televisions.firstIndex(where: { $0.id == television.id }) {
                televisions[index] = television
            } else {
                televisions.append(television)
            }
            televisions.sort {
                let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return $0.brand.rawValue < $1.brand.rawValue
            }
            state = .results
        case .finished:
            finishSearch()
        case .permissionDenied:
            stop(resetState: false)
            state = .permissionDenied
        case .failed:
            stop(resetState: false)
            state = .failed
        }
    }

    private func finishSearch() {
        stop(resetState: false)
        state = televisions.isEmpty ? .noResults : .results
    }
}

/// Non-secret metadata included in Samsung's `_samsungmsf._tcp` Bonjour record.
struct SamsungBonjourMetadata: Equatable, Sendable {
    let reportedIdentifier: String
    let displayName: String
    let advertisedModelName: String?

    init?(txtRecordData: Data?, serviceName: String) {
        guard let txtRecordData else { return nil }
        let record = NetService.dictionary(fromTXTRecord: txtRecordData)

        guard let identifier = Self.value(for: "id", in: record) else { return nil }
        let normalizedIdentifier = identifier.lowercased()
        guard !normalizedIdentifier.isEmpty else { return nil }

        reportedIdentifier = normalizedIdentifier
        displayName = Self.cleaned(
            Self.value(for: "fn", in: record) ?? serviceName,
            fallback: "Samsung TV"
        )
        advertisedModelName = Self.value(for: "md", in: record).map {
            Self.cleaned($0, fallback: "Samsung TV")
        }
    }

    private static func value(for key: String, in record: [String: Data]) -> String? {
        guard let data = record[key], let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let cleanedValue = cleaned(value, fallback: "")
        return cleanedValue.isEmpty ? nil : cleanedValue
    }

    private static func cleaned(_ value: String, fallback: String) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let trimmed = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(80))
    }
}

/// Discovers Samsung TVs through their Bonjour advertisement, then verifies each
/// candidate through the same local device-information endpoint used for pairing.
@MainActor
final class SamsungBonjourDiscoveryBackend: NSObject, TVDiscoveryBackend {
    private struct ValidationOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static let serviceType = "_samsungmsf._tcp."
    private static let policyDeniedErrorCode = -72_008

    private let deviceInfoProvider: any SamsungDeviceInfoProviding
    private var browser: NetServiceBrowser?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var validationTasks: [ObjectIdentifier: ValidationOperation] = [:]
    private var eventHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?

    init(deviceInfoProvider: any SamsungDeviceInfoProviding = SamsungDeviceInfoClient()) {
        self.deviceInfoProvider = deviceInfoProvider
    }

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

        for operation in validationTasks.values {
            operation.task.cancel()
        }
        validationTasks.removeAll()
        eventHandler = nil
    }

    private func validate(_ service: NetService) {
        let serviceID = ObjectIdentifier(service)
        guard
            let metadata = SamsungBonjourMetadata(
                txtRecordData: service.txtRecordData(),
                serviceName: service.name
            ),
            let address = Self.privateIPv4Address(from: service)
        else {
            services[serviceID] = nil
            return
        }

        validationTasks[serviceID]?.task.cancel()
        let operationID = UUID()
        let task = Task { [weak self, deviceInfoProvider] in
            defer {
                if self?.validationTasks[serviceID]?.id == operationID {
                    self?.validationTasks[serviceID] = nil
                    self?.services[serviceID] = nil
                }
            }

            do {
                let deviceInfo = try await deviceInfoProvider.fetchDeviceInfo(at: address)
                try Task.checkCancellation()
                guard deviceInfo.supportsTokenAuthentication else { return }

                self?.eventHandler?(
                    .found(
                        DiscoveredTV(
                            reportedIdentifier: metadata.reportedIdentifier,
                            displayName: metadata.displayName,
                            modelName: deviceInfo.modelName,
                            address: address
                        )
                    )
                )
            } catch {
                // A service advertisement is only a candidate. Invalid, stale,
                // or unsupported devices are omitted without exposing details.
            }
        }
        validationTasks[serviceID] = ValidationOperation(id: operationID, task: task)
    }

    static func privateIPv4Address(from service: NetService) -> PrivateIPv4Address? {
        for addressData in service.addresses ?? [] {
            let rawAddress: String? = addressData.withUnsafeBytes { buffer in
                guard
                    let baseAddress = buffer.baseAddress,
                    buffer.count >= MemoryLayout<sockaddr_in>.size
                else { return nil }
                let socketAddress = baseAddress.assumingMemoryBound(to: sockaddr.self)
                guard Int32(socketAddress.pointee.sa_family) == AF_INET else { return nil }

                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    socketAddress,
                    socklen_t(addressData.count),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard result == 0 else { return nil }
                let utf8 = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return String(decoding: utf8, as: UTF8.self)
            }

            if let rawAddress, let address = try? PrivateIPv4Address(rawAddress) {
                return address
            }
        }
        return nil
    }
}

extension SamsungBonjourDiscoveryBackend: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let serviceID = ObjectIdentifier(service)
        services[serviceID] = service
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

extension SamsungBonjourDiscoveryBackend: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        validate(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        services[ObjectIdentifier(sender)] = nil
    }
}

#if DEBUG
    @MainActor
    final class TVDiscoveryFixtureBackend: TVDiscoveryBackend {
        enum Fixture {
            case television
            case noResults
            case noResultsThenTelevision
        }

        private let fixture: Fixture
        private var startCount = 0

        init(fixture: Fixture) {
            self.fixture = fixture
        }

        func start(
            eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
        ) {
            startCount += 1
            switch fixture {
            case .television:
                publishTelevision(to: eventHandler)
            case .noResults:
                eventHandler(.finished)
            case .noResultsThenTelevision:
                if startCount == 1 {
                    eventHandler(.finished)
                } else {
                    publishTelevision(to: eventHandler)
                }
            }
        }

        func stop() {}

        private func publishTelevision(
            to eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
        ) {
            guard let address = try? PrivateIPv4Address("192.168.10.20") else {
                eventHandler(.failed)
                return
            }
            eventHandler(
                .found(
                    DiscoveredTV(
                        reportedIdentifier: "synthetic-tv",
                        displayName: "Living Room TV",
                        modelName: "Samsung Q70A",
                        address: address
                    )
                )
            )
            eventHandler(.finished)
        }
    }
#endif
