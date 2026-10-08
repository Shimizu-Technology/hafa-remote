import Foundation
import SwiftData
import Testing

@testable import HafaRemote

@MainActor
struct PublicBuildTests {
    @Test("Public host has matching compiled audience and Samsung-only brands")
    func hostConfiguration() {
        #expect(TVBuildFlavor.compiled == .samsungPublic)
        #expect(TVBuildFlavor.isConfigured)
        #expect(TVDistributionPolicy.current.permittedBrands == [.samsung])
        #expect(TVDistributionPolicy.internalCandidate.permittedBrands == [.samsung])
    }

    @Test(
        "Missing, mistyped and cross-audience metadata never validates",
        arguments: ["internal", "PUBLIC", "", "public "])
    func rejectsMismatchedMetadata(value: String) {
        #expect(!TVBuildFlavor.samsungPublic.validatesAudience(value))
    }

    @Test("Audience metadata must be a string")
    func rejectsNonStringMetadata() {
        #expect(!TVBuildFlavor.samsungPublic.validatesAudience(nil))
        #expect(!TVBuildFlavor.samsungPublic.validatesAudience(true))
        #expect(TVDistributionPolicy.unavailable.permittedBrands.isEmpty)
    }

    @Test("A public plist declares only the Samsung service")
    func declarations() {
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] == ["_samsungmsf._tcp"]
        )
    }

    @Test(
        "Experimental connect is rejected before an injected permissive driver is invoked",
        arguments: [TVBrand.sony, .vizio])
    func rejectsForeignConnection(brand: TVBrand) async throws {
        let driver = PublicBoundaryProbeDriver()
        let controller = RemoteSessionController(driver: driver)
        await controller.connect(
            to: TVConnectionTarget(
                brand: brand, reportedDeviceID: "synthetic-foreign",
                address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.49"),
                controlPort: nil))
        #expect(await driver.connections == 0)
        #expect(await controller.state == .unsupported)
        await controller.disconnect()
    }

    @Test(
        "Experimental credential cleanup and forget are refused before touching the driver",
        arguments: [TVBrand.sony, .vizio])
    func rejectsForeignCleanup(brand: TVBrand) async throws {
        let driver = PublicBoundaryProbeDriver()
        let controller = RemoteSessionController(driver: driver)
        let store = RemoteSessionStore(controller: controller)
        await #expect(throws: RemoteCredentialRemovalError.unsupported) {
            try await store.removePairingCredential(
                for: "192.0.2.49", reportedDeviceID: "synthetic-foreign", brand: brand)
        }
        await #expect(throws: RemoteCredentialRemovalError.unsupported) {
            try await store.forgetPairing(
                for: "192.0.2.49", reportedDeviceID: "synthetic-foreign", brand: brand)
        }
        #expect(await driver.removals == 0)
        #expect(await driver.forgets == 0)
    }

    @Test("Discovery drops experimental advertisements even from an injected backend")
    func discoveryFiltersForeignResults() throws {
        let backend = PublicDiscoveryFixture()
        let store = TVDiscoveryStore(backend: backend)
        store.start()
        #expect(store.televisions.map(\.brand) == [.samsung])
        #expect(store.state == .results)
        store.stop()
    }

    @Test("Most-recent experimental records do not displace the eligible Samsung restoration")
    func restoredSelection() async throws {
        let sony = saved(.sony, id: "synthetic-sony", lastUsed: .distantFuture)
        let samsung = saved(.samsung, id: "synthetic-samsung", lastUsed: .distantPast)
        var restored: TVBrand?
        await SavedTVRestorationCoordinator().restore(
            from: [sony, samsung].filter(\.isSupportedInCurrentBuild),
            targetForSavedTV: { record in
                guard
                    let address = try? PrivateIPv4Address(
                        documentationAddressForTesting: record.lastKnownAddress)
                else { return nil }
                return TVConnectionTarget(
                    brand: record.brand, reportedDeviceID: record.reportedDeviceID, address: address,
                    controlPort: nil)
            },
            connect: { restored = $0.brand })
        #expect(restored == .samsung)
        #expect(sony.brandRawValue == "sony")
    }

    @Test(
        "Unknown persisted brands are preserved instead of being admitted through the legacy fallback",
        arguments: ["future-brand", "Samsung", "", "samsung "])
    func unknownBrandsStayUnavailable(raw: String) {
        let record = saved(.samsung, id: "synthetic-unknown")
        record.brandRawValue = raw
        #expect(!record.isSupportedInCurrentBuild)
        #expect(record.brandRawValue == raw)
    }

    @Test("SwiftData upgrade-style processing preserves experimental records and pending removal")
    func persistedExperimentalRecordsSurvive() throws {
        let container = try ModelContainer(
            for: SavedTV.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let sony = saved(.sony, id: "synthetic-sony")
        sony.pendingCredentialRemoval = true
        sony.controlPort = 6466
        let vizio = saved(.vizio, id: "synthetic-vizio")
        vizio.controlPort = 9000
        for record in [sony, vizio] { context.insert(record) }
        try context.save()
        SavedTVLegacyIdentityMigration.apply(
            to: [sony, vizio].filter(\.isSupportedInCurrentBuild), in: context)
        try context.save()
        let restored = try context.fetch(FetchDescriptor<SavedTV>())
        #expect(restored.count == 2)
        #expect(restored.first(where: { $0.brand == .sony })?.pendingCredentialRemoval == true)
        #expect(restored.first(where: { $0.brand == .sony })?.controlPort == 6466)
        #expect(restored.first(where: { $0.brand == .vizio })?.controlPort == 9000)
    }

    @Test("A Samsung preference save retains experimental launch descriptors and keyboard settings")
    func preferencesRoundTrip() throws {
        let suite = "synthetic.public-preservation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sony = try TVAppShortcut(name: "Synthetic Sony favorite", target: .sony(.youtube))
        let vizio = try TVAppShortcut(
            name: "Synthetic Vizio favorite", target: .vizio(appID: "synthetic.vizio", namespace: 1))
        let original: [String: SeedEntry] = [
            "sony:synthetic-sony": SeedEntry(favorites: [sony], keyboardEnabled: false),
            "vizio:synthetic-vizio": SeedEntry(favorites: [vizio], keyboardEnabled: true),
        ]
        defaults.set(try JSONEncoder().encode(original), forKey: "hafaRemote.conveniencePreferences.v1")
        let preferences = TVConveniencePreferences(defaults: defaults)
        let samsung = try TVAppShortcut(
            name: "Synthetic Samsung favorite", target: .samsung(appID: "synthetic.samsung", deepLink: false))
        try preferences.toggleFavorite(samsung, for: "samsung:synthetic-samsung")
        let data = try #require(defaults.data(forKey: "hafaRemote.conveniencePreferences.v1"))
        let after = try JSONDecoder().decode([String: SeedEntry].self, from: data)
        #expect(after["sony:synthetic-sony"] == original["sony:synthetic-sony"])
        #expect(after["vizio:synthetic-vizio"] == original["vizio:synthetic-vizio"])
        #expect(after["samsung:synthetic-samsung"]?.favorites == [samsung])
    }

    @Test("Generic Samsung forget preserves stable identity at a shared cached address")
    func samsungForgetProtocolPreservesStableIdentity() async throws {
        let identityA = try SamsungPairingCredentialIdentity(reportedDeviceID: "synthetic-samsung-a")
        let identityB = try SamsungPairingCredentialIdentity(reportedDeviceID: "synthetic-samsung-b")
        let credentialA = try SamsungPairingCredential(
            token: "synthetic-token-a", certificateSHA256: Data(repeating: 49, count: 32))
        let credentialB = try SamsungPairingCredential(
            token: "synthetic-token-b", certificateSHA256: Data(repeating: 50, count: 32))
        let store = PublicSamsungCredentialFixture()
        await store.save(credentialA, for: identityA)
        await store.save(credentialB, for: identityB)
        let deviceInfo = PublicNoNetworkInfoProvider()
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: deviceInfo, credentialStore: store, transport: PublicNoNetworkTransport())
        let generic: any RemoteSessionDriving = coordinator
        do {
            try await generic.forget(
                addressText: "192.0.2.49", reportedDeviceID: identityA.reportedDeviceID, brand: .samsung)
        } catch {
            Issue.record("Generic dispatch dropped or rejected the supplied stable identity.")
        }
        let sharedAddress = try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.49")
        #expect(await store.credential(for: identityA, discardingLegacyCredentialFor: sharedAddress) == nil)
        #expect(
            await store.credential(for: identityB, discardingLegacyCredentialFor: sharedAddress)
                == credentialB)
        #expect(await deviceInfo.fetches == 0)
        #expect(await store.legacyRemovals == 0)
    }

    private func saved(_ brand: TVBrand, id: String, lastUsed: Date = .distantPast) -> SavedTV {
        SavedTV(
            brand: brand, reportedDeviceID: id, displayName: "Synthetic preserved TV",
            modelName: "Synthetic model", firmwareVersion: nil, lastKnownAddress: "192.0.2.49",
            lastUsedAt: lastUsed)
    }
    private struct SeedEntry: Codable, Equatable {
        var favorites: [TVAppShortcut]
        var keyboardEnabled: Bool
    }
}

private actor PublicBoundaryProbeDriver: RemoteSessionDriving {
    var connections = 0
    var removals = 0
    var forgets = 0
    nonisolated func supports(_ brand: TVBrand) -> Bool { true }
    func connect(addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void)
        async throws -> ConnectedTV
    {
        connections += 1
        return ConnectedTV(
            reportedDeviceID: "synthetic-samsung",
            address: try PrivateIPv4Address(documentationAddressForTesting: addressText),
            modelName: "Synthetic Samsung", firmwareVersion: nil)
    }
    func send(_ command: RemoteCommand) async throws {}
    func removeCredential(addressText: String, reportedDeviceID: String?, brand: TVBrand) async throws {
        removals += 1
    }
    func forget(addressText: String) async throws { forgets += 1 }
    func disconnect() async {}
}

@MainActor
private final class PublicDiscoveryFixture: TVDiscoveryBackend {
    func start(eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void) {
        for brand in TVBrand.allCases {
            eventHandler(
                .found(
                    DiscoveredTV(
                        brand: brand, reportedIdentifier: "synthetic-\(brand.rawValue)",
                        displayName: "Synthetic TV", modelName: "Synthetic model",
                        address: try! PrivateIPv4Address(documentationAddressForTesting: "192.0.2.49"))))
        }
        eventHandler(.finished)
    }
    func stop() {}
}

private actor PublicSamsungCredentialFixture: SamsungPairingCredentialStoring {
    var values: [SamsungPairingCredentialIdentity: SamsungPairingCredential] = [:]
    var legacyRemovals = 0
    func credential(
        for identity: SamsungPairingCredentialIdentity,
        discardingLegacyCredentialFor address: PrivateIPv4Address
    ) -> SamsungPairingCredential? { values[identity] }
    func save(_ credential: SamsungPairingCredential, for identity: SamsungPairingCredentialIdentity) {
        values[identity] = credential
    }
    func removeCredential(for identity: SamsungPairingCredentialIdentity, legacyAddress: PrivateIPv4Address?)
    { values[identity] = nil }
    func removeLegacyCredential(for address: PrivateIPv4Address) { legacyRemovals += 1 }
}
private actor PublicNoNetworkInfoProvider: SamsungDeviceInfoProviding {
    var fetches = 0
    func fetchDeviceInfo(at address: PrivateIPv4Address) throws -> SamsungDeviceInfo {
        fetches += 1
        throw PublicFixtureError.networkingNotAllowed
    }
}
private actor PublicNoNetworkTransport: SamsungTransporting {
    func connect(
        to address: PrivateIPv4Address, using credential: SamsungPairingCredential?,
        attemptID: SamsungConnectionAttemptID
    ) throws -> SamsungPairingCredential { throw PublicFixtureError.networkingNotAllowed }
    func send(_ command: RemoteCommand) {}
    func disconnect(attemptID: SamsungConnectionAttemptID) {}
    func disconnect() {}
}
private enum PublicFixtureError: Error { case networkingNotAllowed }
