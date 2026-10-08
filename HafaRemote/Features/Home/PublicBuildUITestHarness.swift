#if HAFA_PUBLIC_BUILD && DEBUG
    import Observation
    import SwiftData
    import SwiftUI

    /// Public QA exercises the real HomeView with synthetic metadata and no TV or Keychain access.
    struct PublicBuildUITestRoot: View {
        var body: some View {
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-public-mixed") {
                PublicSavedTVHarness(onlyExperimental: false)
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-public-experimental") {
                PublicSavedTVHarness(onlyExperimental: true)
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-discovery-empty") {
                HomeView(discovery: TVDiscoveryStore(backend: TVDiscoveryFixtureBackend(fixture: .noResults)))
            } else {
                HomeView()
            }
        }
    }

    @MainActor @Observable
    private final class PublicFixtureProbe {
        var connections = 0
        var credentialRemovals = 0
    }

    private struct PublicSavedTVHarness: View {
        @Environment(\.modelContext) private var modelContext
        @Query private var records: [SavedTV]
        @State private var probe: PublicFixtureProbe
        @State private var session: RemoteSessionStore
        @State private var didSeed = false
        let onlyExperimental: Bool

        init(onlyExperimental: Bool) {
            self.onlyExperimental = onlyExperimental
            let probe = PublicFixtureProbe()
            _probe = State(initialValue: probe)
            _session = State(
                initialValue: RemoteSessionStore(
                    controller: RemoteSessionController(driver: PublicFixtureDriver(probe: probe))))
        }

        var body: some View {
            HomeView(
                session: session,
                discovery: TVDiscoveryStore(backend: TVDiscoveryFixtureBackend(fixture: .noResults)),
                savedTargetResolver: { record in
                    guard
                        let address = try? PrivateIPv4Address(
                            documentationAddressForTesting: record.lastKnownAddress)
                    else { return nil }
                    return TVConnectionTarget(
                        brand: record.brand, reportedDeviceID: record.reportedDeviceID, address: address,
                        controlPort: record.validatedControlPort,
                        expectedSavedDeviceID: record.reportedDeviceID)
                }
            )
            .safeAreaInset(edge: .bottom) {
                Text(
                    "Saved: \(records.count) · Connections: \(probe.connections) · Removals: \(probe.credentialRemovals)"
                )
                .font(.caption)
                .accessibilityIdentifier("publicPreservationWitness")
                .allowsHitTesting(false)
            }
            .task {
                guard !didSeed else { return }
                didSeed = true
                let sony = SavedTV(
                    brand: .sony, reportedDeviceID: "synthetic-sony-preserved",
                    displayName: "Synthetic Sony Study TV",
                    modelName: "Synthetic Sony", firmwareVersion: nil, lastKnownAddress: "192.0.2.49",
                    lastUsedAt: .distantFuture)
                let vizio = SavedTV(
                    brand: .vizio, reportedDeviceID: "synthetic-vizio-preserved",
                    displayName: "Synthetic Vizio Test TV",
                    modelName: "Synthetic Vizio", firmwareVersion: nil, lastKnownAddress: "192.0.2.50",
                    pendingCredentialRemoval: true)
                modelContext.insert(sony)
                modelContext.insert(vizio)
                if !onlyExperimental {
                    modelContext.insert(
                        SavedTV(
                            reportedDeviceID: "synthetic-samsung-public",
                            displayName: "Synthetic Samsung Living TV", modelName: "Synthetic Samsung",
                            firmwareVersion: nil,
                            lastKnownAddress: "192.0.2.51"))
                }
                try? modelContext.save()
            }
        }
    }

    private actor PublicFixtureDriver: RemoteSessionDriving {
        let probe: PublicFixtureProbe
        init(probe: PublicFixtureProbe) { self.probe = probe }
        func connect(
            addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            await MainActor.run { probe.connections += 1 }
            return ConnectedTV(
                reportedDeviceID: "synthetic-samsung-public",
                address: try PrivateIPv4Address(documentationAddressForTesting: addressText),
                modelName: "Synthetic Samsung", firmwareVersion: nil,
                capabilities: [.navigation, .volume, .mute, .playback, .powerOff])
        }
        func send(_ command: RemoteCommand) async throws {}
        func forget(addressText: String) async throws {
            await MainActor.run { probe.credentialRemovals += 1 }
        }
        func removeCredential(addressText: String, reportedDeviceID: String?, brand: TVBrand) async throws {
            await MainActor.run { probe.credentialRemovals += 1 }
        }
        func disconnect() async {}
    }
#endif
