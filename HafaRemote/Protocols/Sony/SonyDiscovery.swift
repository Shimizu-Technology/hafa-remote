import CryptoKit
@preconcurrency import Foundation

struct SonyBonjourCandidateMetadata: Equatable, Sendable {
    let reportedIdentifier: String
    let displayName: String

    init(serviceName: String) {
        let safeName = Self.cleaned(serviceName)
        displayName = safeName.isEmpty ? "Sony / Google TV" : safeName
        let digest = SHA256.hash(data: Data(serviceName.utf8))
        reportedIdentifier = digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cleaned(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
            .description
    }
}

/// Discovers Android TV Remote Service candidates. The selected endpoint still
/// must identify itself as Sony during the authenticated remote handshake.
@MainActor
final class SonyBonjourDiscoveryBackend: NSObject, TVDiscoveryBackend {
    private static let serviceType = "_androidtvremote2._tcp."
    private static let controlPort = 6466
    private static let policyDeniedErrorCode = -72_008

    private var browser: NetServiceBrowser?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var eventHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?

    deinit {}

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
        guard service.port == Self.controlPort,
            let address = SamsungBonjourDiscoveryBackend.privateIPv4Address(from: service)
        else {
            return
        }
        let metadata = SonyBonjourCandidateMetadata(serviceName: service.name)
        eventHandler?(
            .found(
                DiscoveredTV(
                    brand: .sony,
                    reportedIdentifier: metadata.reportedIdentifier,
                    displayName: metadata.displayName,
                    modelName: "Google TV",
                    address: address,
                    controlPort: UInt16(Self.controlPort)
                )
            )
        )
    }
}

extension SonyBonjourDiscoveryBackend: NetServiceBrowserDelegate {
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

extension SonyBonjourDiscoveryBackend: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        publish(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        services[ObjectIdentifier(sender)] = nil
    }
}

@MainActor
final class CompositeTVDiscoveryBackend: TVDiscoveryBackend {
    private enum TerminalState {
        case finished
        case permissionDenied
        case failed
    }

    private let backends: [any TVDiscoveryBackend]
    private var terminalStates: [Int: TerminalState] = [:]
    private var eventHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?

    deinit {}

    init(backends: [any TVDiscoveryBackend]) {
        precondition(!backends.isEmpty)
        self.backends = backends
    }

    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    ) {
        stop()
        terminalStates = [:]
        self.eventHandler = eventHandler
        for (index, backend) in backends.enumerated() {
            backend.start { [weak self] event in
                self?.receive(event, from: index)
            }
        }
    }

    func stop() {
        for backend in backends { backend.stop() }
        terminalStates = [:]
        eventHandler = nil
    }

    private func receive(_ event: TVDiscoveryBackendEvent, from index: Int) {
        switch event {
        case .found:
            eventHandler?(event)
        case .finished:
            terminalStates[index] = .finished
            publishTerminalStateIfNeeded()
        case .permissionDenied:
            terminalStates[index] = .permissionDenied
            publishTerminalStateIfNeeded()
        case .failed:
            terminalStates[index] = .failed
            publishTerminalStateIfNeeded()
        }
    }

    private func publishTerminalStateIfNeeded() {
        guard terminalStates.count == backends.count else { return }
        let handler = eventHandler
        let result: TVDiscoveryBackendEvent
        if terminalStates.values.contains(where: { state in
            if case .permissionDenied = state { return true }
            return false
        }) {
            result = .permissionDenied
        } else if terminalStates.values.allSatisfy({ state in
            if case .finished = state { return true }
            return false
        }) {
            result = .finished
        } else {
            result = .failed
        }
        stop()
        handler?(result)
    }
}
