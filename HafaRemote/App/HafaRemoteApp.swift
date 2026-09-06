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
                    RemoteControlTestHarness(isConnected: false, powerOffFails: false)
                } else if ProcessInfo.processInfo.arguments.contains(
                    "-ui-testing-remote-power-off-failure"
                ) {
                    RemoteControlTestHarness(isConnected: true, powerOffFails: true)
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-remote") {
                    RemoteControlTestHarness(isConnected: true, powerOffFails: false)
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
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-saved-tvs") {
                    SavedTVSwitchingUITestHarness()
                } else if ProcessInfo.processInfo.arguments.contains(
                    "-ui-testing-malformed-saved-tv"
                ) {
                    MalformedSavedTVUITestHarness()
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

    private struct SavedTVSwitchingUITestHarness: View {
        @Environment(\.modelContext) private var modelContext
        @State private var didSeed = false
        @State private var session: RemoteSessionStore

        init() {
            guard let address = try? PrivateIPv4Address("192.168.10.20") else {
                preconditionFailure("The fixed UI-test address must remain valid")
            }
            let television = ConnectedTV(
                brand: .samsung,
                reportedDeviceID: "fixture-samsung",
                address: address,
                controlPort: 8_002,
                modelName: "Q70AA",
                firmwareVersion: "1.0"
            )
            let initialState = RemoteSessionState.connected(television)
            _session = State(
                initialValue: RemoteSessionStore(
                    controller: RemoteSessionController(
                        driver: SavedTVSwitchingUIFixtureDriver(),
                        initialState: initialState
                    ),
                    initialState: initialState
                )
            )
        }

        var body: some View {
            Group {
                if didSeed {
                    HomeView(session: session)
                } else {
                    ProgressView("Preparing TVs…")
                }
            }
            .task {
                guard !didSeed else { return }
                let existing = (try? modelContext.fetch(FetchDescriptor<SavedTV>())) ?? []
                for savedTV in existing {
                    modelContext.delete(savedTV)
                }
                modelContext.insert(
                    SavedTV(
                        brand: .samsung,
                        reportedDeviceID: "fixture-samsung",
                        displayName: "Living Room TV",
                        roomName: "Living Room",
                        modelName: "Q70AA",
                        firmwareVersion: "1.0",
                        lastKnownAddress: "192.168.10.20",
                        controlPort: 8_002,
                        lastUsedAt: Date(timeIntervalSince1970: 200)
                    )
                )
                modelContext.insert(
                    SavedTV(
                        brand: .sony,
                        reportedDeviceID: "fixture-sony",
                        displayName: "Side Door TV",
                        roomName: "Side Door",
                        modelName: "Sony BRAVIA",
                        firmwareVersion: "1.0",
                        lastKnownAddress: "192.168.10.21",
                        controlPort: 6_466,
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    )
                )
                try? modelContext.save()
                didSeed = true
            }
        }
    }

    private struct MalformedSavedTVUITestHarness: View {
        @Environment(\.modelContext) private var modelContext
        @State private var didSeed = false

        /// Seeds an invalid legacy endpoint so UI tests can prove recovery remains reachable.
        var body: some View {
            Group {
                if didSeed {
                    HomeView(
                        session: RemoteSessionStore(
                            controller: RemoteSessionController(
                                driver: MalformedSavedTVUIFixtureDriver()
                            )
                        )
                    )
                } else {
                    ProgressView("Preparing TV…")
                }
            }
            .task {
                guard !didSeed else { return }
                modelContext.insert(
                    SavedTV(
                        reportedDeviceID: "fixture-malformed",
                        displayName: "Needs Setup",
                        modelName: "Unknown model",
                        firmwareVersion: nil,
                        lastKnownAddress: "not-an-address"
                    )
                )
                try? modelContext.save()
                didSeed = true
            }
        }
    }

    private actor MalformedSavedTVUIFixtureDriver: RemoteSessionDriving {
        /// The recovery fixture never opens a connection.
        func connect(
            addressText: String,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            throw SamsungConnectionError.unavailable
        }

        /// The recovery fixture never sends commands.
        func send(_ command: RemoteCommand) async throws {}

        /// Simulates successful local removal independent of simulator Keychain entitlements.
        func forget(addressText: String) async throws {}

        /// Simulates scoped credential removal for the malformed saved record.
        func removeCredential(
            addressText: String,
            reportedDeviceID: String?,
            brand: TVBrand
        ) async throws {}

        /// The recovery fixture owns no transport.
        func disconnect() {}
    }
#endif
