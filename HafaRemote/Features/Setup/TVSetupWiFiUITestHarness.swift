#if DEBUG && !HAFA_PUBLIC_BUILD
    import Observation
    import SwiftUI

    /// Synthetic operator controls drive actual setup's observable network hints.
    struct TVSetupWiFiUITestHarness: View {
        @State private var network: LocalNetworkMonitor
        @State private var session: RemoteSessionStore
        @State private var discovery: TVDiscoveryStore
        @State private var isShowingSetup = false
        @State private var probe = WiFiDiscoveryUIProbe()

        init() {
            let arguments = ProcessInfo.processInfo.arguments
            let probe = WiFiDiscoveryUIProbe()
            _probe = State(initialValue: probe)
            _network = State(
                initialValue: LocalNetworkMonitor(
                    fixedReachability: arguments.contains("-ui-testing-wifi-offline") ? false : true))
            _session = State(
                initialValue: RemoteSessionStore(
                    controller: RemoteSessionController(driver: VizioPairingUIFixtureDriver())))
            _discovery = State(
                initialValue: TVDiscoveryStore(
                    backend: WiFiDiscoveryUIBackend(
                        probe: probe, partial: arguments.contains("-ui-testing-wifi-partial"),
                        advertised: arguments.contains("-ui-testing-wifi-advertised"),
                        hold: arguments.contains("-ui-testing-wifi-hold")), searchDuration: .seconds(60)))
        }

        var body: some View {
            VStack {
                Button("Add TV") { isShowingSetup = true }
                    .accessibilityIdentifier("addTVButton")
                Text(session.canSendCommands ? "Connected" : "Not connected")
                    .accessibilityIdentifier("wifiFixtureConnection")
            }
            .sheet(isPresented: $isShowingSetup) {
                TVSetupView(session: session, discovery: discovery, networkMonitor: network)
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Button("Wi-Fi unavailable") { network.setReachabilityForTesting(false) }
                                .accessibilityIdentifier("wifiFixtureDisconnect")
                            Button("Restore Wi-Fi") { network.setReachabilityForTesting(true) }
                                .accessibilityIdentifier("wifiFixtureRestore")
                            Button("Finish search") { probe.finishSearch?() }
                                .accessibilityIdentifier("wifiFixtureFinish")
                            Text(String(probe.starts))
                                .accessibilityIdentifier("wifiFixtureScans")
                        }
                        .font(.caption)
                        .padding(8)
                        .background(.bar)
                    }
            }
        }
    }

    @MainActor @Observable
    private final class WiFiDiscoveryUIProbe {
        var starts = 0
        @ObservationIgnored var finishSearch: (@MainActor () -> Void)?
    }

    @MainActor
    private final class WiFiDiscoveryUIBackend: TVDiscoveryBackend {
        let probe: WiFiDiscoveryUIProbe
        let partial: Bool
        let advertised: Bool
        let hold: Bool
        private var pendingHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?

        init(probe: WiFiDiscoveryUIProbe, partial: Bool, advertised: Bool, hold: Bool) {
            self.probe = probe
            self.partial = partial
            self.advertised = advertised
            self.hold = hold
        }

        func start(eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void) {
            probe.starts += 1
            if partial {
                publish(brand: .sony, to: eventHandler)
                if advertised && probe.starts == 1 {
                    eventHandler(.progress(TVDiscoveryProgress(brand: .vizio, stage: .advertised)))
                }
            }
            if !partial || probe.starts > 1 { publish(brand: .vizio, to: eventHandler) }
            if hold && probe.starts == 1 {
                pendingHandler = eventHandler
                probe.finishSearch = { [weak self] in
                    let handler = self?.pendingHandler
                    self?.pendingHandler = nil
                    handler?(.finished)
                }
            } else {
                eventHandler(.finished)
            }
        }

        func stop() {
            pendingHandler = nil
            probe.finishSearch = nil
        }

        private func publish(
            brand: TVBrand,
            to eventHandler: @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
        ) {
            guard let address = try? PrivateIPv4Address(documentationAddressForTesting: "192.0.2.30") else {
                return
            }
            eventHandler(
                .found(
                    DiscoveredTV(
                        brand: brand, reportedIdentifier: "synthetic-wifi-\(brand.rawValue)",
                        displayName: "Synthetic \(brand.displayName) TV", modelName: "Synthetic TV",
                        address: address, controlPort: brand == .sony ? 6466 : 7345)))
        }
    }
#endif
