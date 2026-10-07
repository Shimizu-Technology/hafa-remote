import Observation
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
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-saved-sony-alias") {
                    SavedSonyAssociationUITestHarness(mode: .unique)
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-colliding-sony-alias") {
                    SavedSonyAssociationUITestHarness(mode: .colliding)
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-fresh-sony-rejection") {
                    SavedSonyAssociationUITestHarness(mode: .fresh)
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-remote-offline") {
                    RemoteControlTestHarness(
                        isConnected: false,
                        isAwaitingApproval: false,
                        powerOffFails: false
                    )
                } else if ProcessInfo.processInfo.arguments.contains(
                    "-ui-testing-remote-pairing"
                ) {
                    RemoteControlTestHarness(
                        isConnected: false,
                        isAwaitingApproval: true,
                        powerOffFails: false
                    )
                } else if ProcessInfo.processInfo.arguments.contains(
                    "-ui-testing-remote-power-off-failure"
                ) {
                    RemoteControlTestHarness(
                        isConnected: true,
                        isAwaitingApproval: false,
                        powerOffFails: true
                    )
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-remote") {
                    RemoteControlTestHarness(
                        isConnected: true,
                        isAwaitingApproval: false,
                        powerOffFails: false
                    )
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
    /// Exercises actual setup association and error projection with no network or Keychain.
    private struct SavedSonyAssociationUITestHarness: View {
        enum Mode { case unique, colliding, fresh }
        @Environment(\.modelContext) private var modelContext
        @State private var didSeed = false
        @State private var session: RemoteSessionStore
        @State private var discovery: TVDiscoveryStore
        @State private var probe: SavedSonyAssociationUIProbe
        let mode: Mode

        init(mode: Mode) {
            self.mode = mode
            let probe = SavedSonyAssociationUIProbe()
            _probe = State(initialValue: probe)
            _session = State(
                initialValue: RemoteSessionStore(
                    controller: RemoteSessionController(
                        driver: SavedSonyAssociationUIFixtureDriver {
                            target in
                            probe.connectionAttempts += 1
                            probe.expectedIdentity = target?.expectedSavedDeviceID ?? "none"
                            if target == nil { probe.addressBasedAttempts += 1 }
                        } onForget: {
                            probe.forgetAttempts += 1
                        })
                ))
            _discovery = State(initialValue: TVDiscoveryStore(backend: SavedSonyAliasDiscoveryFixture()))
        }

        var body: some View {
            Group {
                if didSeed {
                    TVSetupView(session: session, discovery: discovery)
                } else {
                    ProgressView("Preparing synthetic saved TVs…")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                VStack {
                    Text(String(probe.connectionAttempts))
                        .accessibilityIdentifier("sonyAssociationConnectionAttempts")
                    Text(probe.expectedIdentity)
                        .accessibilityIdentifier("sonyAssociationExpectedIdentity")
                    Text(String(probe.addressBasedAttempts))
                        .accessibilityIdentifier("sonyAssociationAddressBasedAttempts")
                    Text(String(probe.forgetAttempts))
                        .accessibilityIdentifier("sonyAssociationForgetAttempts")
                }
                .font(.caption2)
                .opacity(0.01)
            }
            .task {
                guard !didSeed else { return }
                if mode != .fresh {
                    modelContext.insert(
                        savedTV(identity: "synthetic-authenticated-sony-a", name: "Synthetic Den TV"))
                }
                if mode == .colliding {
                    modelContext.insert(
                        savedTV(identity: "synthetic-authenticated-sony-b", name: "Synthetic Study TV"))
                }
                do {
                    try modelContext.save()
                    didSeed = true
                } catch {
                    preconditionFailure("The synthetic in-memory saved-TV fixture must persist")
                }
            }
        }

        private func savedTV(identity: String, name: String) -> SavedTV {
            SavedTV(
                brand: .sony, reportedDeviceID: identity, displayName: name,
                modelName: "Synthetic BRAVIA", firmwareVersion: "synthetic-firmware",
                lastKnownAddress: "198.51.100.42", controlPort: 6466,
                discoveryIdentifier: SavedSonyAliasDiscoveryFixture.alias
            )
        }
    }

    @MainActor
    @Observable
    private final class SavedSonyAssociationUIProbe {
        var connectionAttempts = 0
        var expectedIdentity = "none"
        var addressBasedAttempts = 0
        var forgetAttempts = 0
    }

    @MainActor
    private final class SavedSonyAliasDiscoveryFixture: TVDiscoveryBackend {
        static let alias = "synthetic-shared-sony-advertisement"
        func start(eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void) {
            guard let address = try? PrivateIPv4Address(documentationAddressForTesting: "192.0.2.42") else {
                preconditionFailure("The RFC 5737 UI fixture address must remain valid")
            }
            eventHandler(
                .found(
                    DiscoveredTV(
                        brand: .sony, reportedIdentifier: Self.alias,
                        displayName: "Synthetic Nearby Sony", modelName: "Synthetic BRAVIA",
                        address: address, controlPort: 6466
                    )))
            eventHandler(.finished)
        }
        func stop() {}
    }

    private actor SavedSonyAssociationUIFixtureDriver: RemoteSessionDriving {
        nonisolated var brand: TVBrand { .sony }
        let onAttempt: @MainActor @Sendable (TVConnectionTarget?) -> Void
        let onForget: @MainActor @Sendable () -> Void
        init(
            onAttempt: @escaping @MainActor @Sendable (TVConnectionTarget?) -> Void,
            onForget: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onAttempt = onAttempt
            self.onForget = onForget
        }
        func connect(
            to target: TVConnectionTarget,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            await onAttempt(target)
            throw SonyPairingCoordinatorError.pairingRejected
        }
        func connect(
            addressText: String,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            await onAttempt(nil)
            throw SonyPairingCoordinatorError.pairingRejected
        }
        func send(_ command: RemoteCommand) {}
        func forget(addressText: String) async { await onForget() }
        func disconnect() {}
    }

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
        @State private var networkMonitor: LocalNetworkMonitor
        @State private var connectionProbe: SavedTVConnectionUITestProbe

        init() {
            let probe = SavedTVConnectionUITestProbe()
            _connectionProbe = State(initialValue: probe)
            _session = State(
                initialValue: RemoteSessionStore(
                    controller: RemoteSessionController(
                        driver: SavedTVSwitchingUIFixtureDriver(
                            delaysRepeatedConnections: ProcessInfo.processInfo.arguments.contains(
                                "-ui-testing-saved-tv-lifecycle"
                            ),
                            onConnectionCompleted: { count in
                                probe.completedConnections = count
                            }
                        )
                    )
                )
            )
            _networkMonitor = State(initialValue: LocalNetworkMonitor(fixedReachability: true))
        }

        var body: some View {
            Group {
                if didSeed {
                    HomeView(session: session, networkMonitor: networkMonitor)
                } else {
                    ProgressView("Preparing TVs…")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(String(connectionProbe.completedConnections))
                    .font(.caption2)
                    .opacity(0.01)
                    .accessibilityIdentifier("savedTVCompletedConnections")
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
                modelContext.insert(
                    SavedTV(
                        brand: .vizio,
                        reportedDeviceID: "fixture-malformed-fallback",
                        displayName: "Old Guest Room TV",
                        roomName: "Guest Room",
                        modelName: "Unknown model",
                        firmwareVersion: nil,
                        lastKnownAddress: "not-an-address",
                        lastUsedAt: Date(timeIntervalSince1970: 150)
                    )
                )
                try? modelContext.save()
                didSeed = true
            }
        }
    }

    @MainActor
    @Observable
    private final class SavedTVConnectionUITestProbe {
        var completedConnections = 0
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
