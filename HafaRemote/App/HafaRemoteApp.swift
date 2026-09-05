import SwiftData
import SwiftUI

/// The iPhone application entry point for Hafa Remote.
@main
struct HafaRemoteApp: App {
    private var usesInMemoryStore: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-store")
        #else
            false
        #endif
    }

    /// Builds the app's root scene.
    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-remote-offline") {
                    RemoteControlTestHarness(isConnected: false)
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-remote") {
                    RemoteControlTestHarness(isConnected: true)
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-discovery-result") {
                    HomeView(
                        discovery: TVDiscoveryStore(
                            backend: TVDiscoveryFixtureBackend(fixture: .television)
                        )
                    )
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-sony-pairing") {
                    HomeView(
                        session: RemoteSessionStore(
                            controller: RemoteSessionController(driver: SonyPairingUIFixtureDriver())
                        ),
                        discovery: TVDiscoveryStore(
                            backend: TVDiscoveryFixtureBackend(fixture: .sonyTelevision)
                        )
                    )
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-vizio-pairing") {
                    HomeView(
                        session: RemoteSessionStore(
                            controller: RemoteSessionController(driver: VizioPairingUIFixtureDriver())
                        ),
                        discovery: TVDiscoveryStore(
                            backend: TVDiscoveryFixtureBackend(fixture: .vizioTelevision)
                        )
                    )
                } else if ProcessInfo.processInfo.arguments.contains(
                    "-ui-testing-vizio-pairing-repair"
                ) {
                    VizioPairingRepairUITestHarness()
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-discovery-empty") {
                    HomeView(
                        discovery: TVDiscoveryStore(
                            backend: TVDiscoveryFixtureBackend(fixture: .noResults)
                        )
                    )
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-discovery-retry") {
                    HomeView(
                        discovery: TVDiscoveryStore(
                            backend: TVDiscoveryFixtureBackend(
                                fixture: .noResultsThenTelevision)
                        )
                    )
                } else {
                    HomeView()
                }
            #else
                HomeView()
            #endif
        }
        .modelContainer(for: SavedTV.self, inMemory: usesInMemoryStore)
    }
}

#if DEBUG
    private struct VizioPairingRepairUITestHarness: View {
        private let target: TVConnectionTarget
        @State private var session: RemoteSessionStore

        init() {
            guard let address = try? PrivateIPv4Address("192.168.10.52") else {
                preconditionFailure("The fixed UI-test address must remain valid")
            }
            target = TVConnectionTarget(
                brand: .vizio,
                reportedDeviceID: "synthetic-vizio-serial",
                address: address,
                controlPort: 7345
            )
            _session = State(
                initialValue: RemoteSessionStore(
                    controller: RemoteSessionController(
                        driver: VizioPairingRepairUIFixtureDriver(),
                        initialState: .savedPairingRejected
                    )
                )
            )
        }

        var body: some View {
            TVSetupView(
                session: session,
                initialTarget: target,
                discovery: TVDiscoveryStore(
                    backend: TVDiscoveryFixtureBackend(fixture: .noResults)
                )
            )
        }
    }
#endif
