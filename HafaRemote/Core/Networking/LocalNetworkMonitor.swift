import Foundation
import Network
import Observation

/// Supplies reachability hints; the TV handshake remains the source of connection truth.
@MainActor
@Observable
final class LocalNetworkMonitor {
    private(set) var isReachable: Bool?

    private let monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.shimizutechnology.hafaremote.network-path")

    init(monitor: NWPathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable: Bool? =
                switch path.status {
                case .satisfied: true
                case .unsatisfied: false
                case .requiresConnection: nil
                @unknown default: nil
                }
            Task { @MainActor in
                self?.isReachable = isReachable
            }
        }
        monitor.start(queue: queue)
    }

    #if DEBUG
        /// Provides a stable path hint for deterministic lifecycle UI tests.
        init(fixedReachability: Bool?) {
            monitor = nil
            isReachable = fixedReachability
        }

        func setReachabilityForTesting(_ value: Bool?) {
            precondition(monitor == nil)
            isReachable = value
        }
    #endif

    static func applicationMonitor() -> LocalNetworkMonitor {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-store") {
                return LocalNetworkMonitor(fixedReachability: true)
            }
        #endif
        return LocalNetworkMonitor()
    }

    isolated deinit {
        monitor?.cancel()
    }
}
