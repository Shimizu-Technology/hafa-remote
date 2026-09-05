import Foundation
import Network
import Observation

/// Supplies reachability hints; the TV handshake remains the source of connection truth.
@MainActor
@Observable
final class LocalNetworkMonitor {
    private(set) var isReachable: Bool?

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.shimizutechnology.hafaremote.network-path")

    init(monitor: NWPathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            Task { @MainActor in
                self?.isReachable = isReachable
            }
        }
        monitor.start(queue: queue)
    }

    isolated deinit {
        monitor.cancel()
    }
}
