import Foundation
import SwiftData
import Testing

@testable import HafaRemote

struct SavedTVTests {
    @Test("Rejected remembered pairing requires explicit selected-TV management")
    func savedRepairCannotBecomeFreshPairingSilently() throws {
        let target = TVConnectionTarget(
            brand: .sony, reportedDeviceID: "synthetic-alias",
            address: try PrivateIPv4Address(documentationAddressForTesting: "198.51.100.49"),
            controlPort: 6466,
            expectedSavedDeviceID: String(repeating: "a", count: 64)
        )
        #expect(SavedTVPairingRecovery.requiresManagement(state: .certificateChanged, target: target))
        #expect(SavedTVPairingRecovery.requiresManagement(state: .savedPairingRejected, target: target))
        #expect(!SavedTVPairingRecovery.requiresManagement(state: .offline, target: target))
        #expect(
            !SavedTVPairingRecovery.requiresManagement(
                state: .certificateChanged, target: target.expectingSavedIdentity(nil)))
    }

    @MainActor
    @Test("Colliding saved discovery aliases require a deliberate choice in either order")
    func collidingAliasesNeverPickAnArbitraryPin() throws {
        let alias = "synthetic-colliding-service-alias"
        let first = SavedTV(
            brand: .sony, reportedDeviceID: String(repeating: "a", count: 64),
            displayName: "Synthetic First TV",
            modelName: "Synthetic BRAVIA", firmwareVersion: nil, lastKnownAddress: "203.0.113.45",
            discoveryIdentifier: alias
        )
        let second = SavedTV(
            brand: .sony, reportedDeviceID: String(repeating: "b", count: 64),
            displayName: "Synthetic Second TV",
            modelName: "Synthetic BRAVIA", firmwareVersion: nil, lastKnownAddress: "203.0.113.46",
            discoveryIdentifier: alias
        )
        let candidate = DiscoveredTV(
            brand: .sony, reportedIdentifier: alias, displayName: "Synthetic Candidate",
            modelName: "Synthetic BRAVIA",
            address: try PrivateIPv4Address(documentationAddressForTesting: "203.0.113.47"), controlPort: 6466
        )
        for records in [[first, second], [second, first]] {
            guard
                case .requiresChoice(let matches) = SavedTVDiscoveryAssociation.resolve(
                    candidate, savedTVs: records)
            else {
                Issue.record("A collision must not choose a saved pin or begin new pairing")
                continue
            }
            #expect(
                Set(matches.map(\.reportedDeviceID)) == [first.reportedDeviceID, second.reportedDeviceID])
        }
    }

    @MainActor
    @Test("A Sony candidate hash alone cannot associate with a legacy saved certificate")
    func legacySonyNeedsAuthenticatedReselection() throws {
        let hash = String(repeating: "a", count: 64)
        let legacy = SavedTV(
            brand: .sony, reportedDeviceID: hash, displayName: "Synthetic Legacy Sony",
            modelName: "Synthetic BRAVIA", firmwareVersion: nil, lastKnownAddress: "192.0.2.47"
        )
        let candidate = DiscoveredTV(
            brand: .sony, reportedIdentifier: hash, displayName: "Synthetic Candidate",
            modelName: "Synthetic BRAVIA",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.48"), controlPort: 6466
        )
        guard
            case .newCandidate(let target) = SavedTVDiscoveryAssociation.resolve(
                candidate, savedTVs: [legacy])
        else {
            Issue.record("An unassociated service hash must never select a certificate pin")
            return
        }
        #expect(target.expectedSavedDeviceID == nil)
    }

    @MainActor
    @Test(
        "Stable Samsung and Vizio IDs can associate with legacy saved records",
        arguments: [TVBrand.samsung, .vizio])
    func stableBrandIDsAssociateSavedTarget(brand: TVBrand) throws {
        let saved = SavedTV(
            brand: brand, reportedDeviceID: "synthetic-stable-id", displayName: "Synthetic Saved TV",
            modelName: "Synthetic Model", firmwareVersion: nil, lastKnownAddress: "198.51.100.47"
        )
        let candidate = DiscoveredTV(
            brand: brand, reportedIdentifier: "synthetic-stable-id", displayName: "Synthetic Candidate",
            modelName: "Synthetic Model",
            address: try PrivateIPv4Address(documentationAddressForTesting: "198.51.100.48"),
            controlPort: brand == .samsung ? 8002 : 7345
        )
        guard case .saved(let target) = SavedTVDiscoveryAssociation.resolve(candidate, savedTVs: [saved])
        else {
            Issue.record("The stable brand-scoped identifier should locate the saved TV")
            return
        }
        #expect(target.expectedSavedDeviceID == saved.reportedDeviceID)
        saved.pendingCredentialRemoval = true
        guard case .newCandidate = SavedTVDiscoveryAssociation.resolve(candidate, savedTVs: [saved]) else {
            Issue.record("Pending-removal credentials must not be selected")
            return
        }
    }

    @MainActor
    @Test("New saved records retain negotiated evidence without granting hardware proof")
    func firstSaveRetainsEvidence() throws {
        let evidence = TVCapabilityEvidence(
            implemented: TVCapability.implemented(for: .sony),
            protocolReported: [.navigation, .playback]
        )
        let saved = SavedTV(
            brand: .sony, reportedDeviceID: "synthetic-evidence-tv", displayName: "Synthetic TV",
            modelName: "Synthetic Model", firmwareVersion: "1", lastKnownAddress: "203.0.113.45",
            capabilities: evidence.internalAvailable, capabilityEvidence: evidence
        )
        #expect(saved.capabilities == [.navigation, .playback])
        #expect(saved.protocolCapabilitiesRawValue == "navigation,playback")
        #expect(saved.hardwareVerifiedCapabilities.isEmpty)
    }
    @MainActor
    @Test("Old automatic wake flags cannot become hardware capability evidence")
    func legacyWakeFlagDoesNotVerifyHardware() throws {
        let saved = SavedTV(
            brand: .sony, reportedDeviceID: "synthetic-observed-tv", displayName: "Synthetic TV",
            modelName: "Synthetic Model", firmwareVersion: "1", lastKnownAddress: "192.0.2.45",
            wakeWasVerified: true
        )
        let television = ConnectedTV(
            brand: .sony, reportedDeviceID: saved.reportedDeviceID,
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.45"),
            modelName: saved.modelName, firmwareVersion: "1", powerState: .on
        )
        saved.recordConnection(to: television)
        #expect(saved.hardwareVerifiedCapabilities.isEmpty)
        saved.hardwareCapabilitiesRawValue = "powerOn"
        saved.recordConnection(to: television)
        #expect(saved.hardwareVerifiedCapabilities == [.powerOn])
        saved.recordConnection(
            to: ConnectedTV(
                brand: .sony, reportedDeviceID: saved.reportedDeviceID, address: television.address,
                modelName: saved.modelName, firmwareVersion: "2"
            ))
        #expect(saved.hardwareVerifiedCapabilities.isEmpty)
    }

    /// Saved metadata remains available after SwiftData persistence and fetch.
    @MainActor
    @Test("Saved TV metadata survives an in-memory SwiftData round trip")
    func roundTripsMetadata() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedTV.self, configurations: configuration)
        let context = container.mainContext
        let saved = SavedTV(
            brand: .sony,
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            roomName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: "2210",
            lastKnownAddress: "192.168.10.20",
            controlPort: 6466,
            discoveryIdentifier: "synthetic-discovery-alias",
            macAddress: "02:00:5E:10:00:01",
            wakeWasVerified: true,
            lastSeenAt: Date(timeIntervalSince1970: 100),
            lastUsedAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(saved)
        try context.save()

        let restoredContext = ModelContext(container)
        let fetched = try restoredContext.fetch(FetchDescriptor<SavedTV>())

        #expect(fetched.count == 1)
        #expect(fetched.first?.brand == .sony)
        #expect(fetched.first?.stableDeviceKey == "sony:synthetic-device-id")
        #expect(fetched.first?.reportedDeviceID == "synthetic-device-id")
        #expect(fetched.first?.displayName == "Living Room")
        #expect(fetched.first?.roomName == "Living Room")
        #expect(fetched.first?.modelName == "Q70AA")
        #expect(fetched.first?.firmwareVersion == "2210")
        #expect(fetched.first?.validatedAddress == (try PrivateIPv4Address("192.168.10.20")))
        #expect(fetched.first?.validatedControlPort == 6466)
        #expect(fetched.first?.discoveryIdentifier == "synthetic-discovery-alias")
        #expect(fetched.first?.connectionTarget?.expectedSavedDeviceID == "synthetic-device-id")
        #expect(fetched.first?.connectionTarget?.discoveryDeviceKey == "sony:synthetic-discovery-alias")
        #expect(fetched.first?.validatedMACAddress == (try SamsungMACAddress("02:00:5E:10:00:01")))
        #expect(fetched.first?.wakeWasVerified == true)
        #expect(fetched.first?.pendingCredentialRemoval == false)
        #expect(fetched.first?.capabilities.contains(.powerOn) == true)
        #expect(fetched.first?.capabilities.contains(.textInput) == false)
        #expect(fetched.first?.lastSeenAt == Date(timeIntervalSince1970: 100))
        #expect(fetched.first?.lastUsedAt == Date(timeIntervalSince1970: 200))
        #expect(fetched.first?.description == "SavedTV(redacted)")
    }

    @MainActor
    @Test("Connected capabilities replace saved capability metadata")
    func recordsConnectedCapabilities() throws {
        let saved = SavedTV(
            brand: .samsung,
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20"
        )
        let connected = ConnectedTV(
            brand: .samsung,
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.21"),
            modelName: "Q70AA",
            firmwareVersion: "2210",
            capabilities: [.navigation, .volume]
        )

        saved.recordConnection(to: connected)

        #expect(saved.capabilities == [.navigation, .volume])
        #expect(saved.rememberedTV?.capabilities == [.navigation, .volume])
    }

    @MainActor
    @Test("An explicitly empty capability set survives persistence")
    func preservesExplicitlyEmptyCapabilities() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedTV.self, configurations: configuration)
        let saved = SavedTV(
            brand: .vizio,
            reportedDeviceID: "synthetic-device-id",
            displayName: "Limited TV",
            modelName: "TEST_MODEL",
            firmwareVersion: nil,
            lastKnownAddress: "192.0.2.20",
            capabilities: []
        )
        container.mainContext.insert(saved)
        try container.mainContext.save()

        let restoredContext = ModelContext(container)
        let restored = try #require(
            restoredContext.fetch(FetchDescriptor<SavedTV>()).first
        )

        #expect(restored.capabilitiesRawValue == "none")
        #expect(restored.capabilities.isEmpty)
    }

    @Test("A missing legacy capability value uses safe brand defaults")
    func defaultsOnlyMissingLegacyCapabilities() {
        let saved = SavedTV(
            brand: .sony,
            reportedDeviceID: "synthetic-device-id",
            displayName: "Legacy TV",
            modelName: "TEST_MODEL",
            firmwareVersion: nil,
            lastKnownAddress: "192.0.2.20",
            capabilities: []
        )
        saved.capabilitiesRawValue = ""

        #expect(saved.capabilities == TVCapability.implemented(for: .sony))
    }

    @Test("Existing Samsung records keep a safe brand default")
    func defaultsLegacyRecordsToSamsung() {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20"
        )

        #expect(saved.brand == .samsung)
        #expect(saved.stableDeviceKey == "samsung:synthetic-device-id")
        #expect(saved.validatedControlPort == nil)
    }

    @MainActor
    @Test("A legacy-shaped on-disk record receives its stable Samsung identity")
    func backfillsPersistedLegacyIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hafa-remote-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "SavedTV.store")
        let schema = Schema([SavedTV.self])

        do {
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let legacyRecord = SavedTV(
                reportedDeviceID: "legacy-device-id",
                displayName: "Living Room",
                modelName: "Q70AA",
                firmwareVersion: nil,
                lastKnownAddress: "192.168.10.20"
            )
            legacyRecord.stableDeviceID = nil
            container.mainContext.insert(legacyRecord)
            try container.mainContext.save()
        }

        do {
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let records = try container.mainContext.fetch(FetchDescriptor<SavedTV>())
            let record = try #require(records.first)
            #expect(record.stableDeviceID == nil)
            #expect(record.brand == .samsung)
            #expect(record.validatedControlPort == nil)

            record.backfillLegacyIdentityIfNeeded()
            try container.mainContext.save()
        }

        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let records = try container.mainContext.fetch(FetchDescriptor<SavedTV>())
        let migrated = try #require(records.first)
        #expect(migrated.brand == .samsung)
        #expect(migrated.stableDeviceID == "samsung:legacy-device-id")
        #expect(migrated.validatedControlPort == nil)
    }

    @MainActor
    @Test("Duplicate legacy Samsung identities are merged before stable backfill")
    func deduplicatesPersistedLegacyIdentities() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hafa-remote-duplicates-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "SavedTV.store")
        let schema = Schema([SavedTV.self])

        do {
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let older = SavedTV(
                reportedDeviceID: "duplicate-device-id",
                displayName: "Older record",
                modelName: "Q70AA",
                firmwareVersion: nil,
                lastKnownAddress: "192.168.10.20",
                lastUsedAt: Date(timeIntervalSince1970: 100)
            )
            let newer = SavedTV(
                reportedDeviceID: "duplicate-device-id",
                displayName: "Newer record",
                modelName: "Q70AA",
                firmwareVersion: nil,
                lastKnownAddress: "192.168.10.21",
                lastUsedAt: Date(timeIntervalSince1970: 200)
            )
            older.stableDeviceID = nil
            newer.stableDeviceID = nil
            container.mainContext.insert(older)
            container.mainContext.insert(newer)
            try container.mainContext.save()
        }

        do {
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let records = try container.mainContext.fetch(FetchDescriptor<SavedTV>())
            #expect(records.count == 2)

            #expect(
                SavedTVLegacyIdentityMigration.apply(
                    to: records,
                    in: container.mainContext
                )
            )
            try container.mainContext.save()
        }

        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let records = try container.mainContext.fetch(FetchDescriptor<SavedTV>())
        let survivor = try #require(records.first)
        #expect(records.count == 1)
        #expect(survivor.displayName == "Newer record")
        #expect(survivor.lastKnownAddress == "192.168.10.21")
        #expect(survivor.stableDeviceID == "samsung:duplicate-device-id")
    }

    @Test("Persisted control port zero is rejected")
    func rejectsControlPortZero() {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "TV",
            modelName: "TEST_MODEL",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20",
            controlPort: 0
        )

        #expect(saved.validatedControlPort == nil)
    }

    @Test("Brand-scoped identity prevents cross-brand device collisions")
    @MainActor
    func scopesIdentityByBrand() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let samsung = ConnectedTV(
            brand: .samsung,
            reportedDeviceID: "synthetic-device-id",
            address: address,
            modelName: "Q70AA",
            firmwareVersion: nil
        )
        let vizio = ConnectedTV(
            brand: .vizio,
            reportedDeviceID: "synthetic-device-id",
            address: address,
            controlPort: 7345,
            modelName: "V-Series",
            firmwareVersion: nil
        )

        #expect(samsung.stableDeviceKey != vizio.stableDeviceKey)
        #expect(vizio.stableDeviceKey == "vizio:synthetic-device-id")

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedTV.self, configurations: configuration)
        let context = container.mainContext
        context.insert(
            SavedTV(
                brand: .samsung,
                reportedDeviceID: samsung.reportedDeviceID,
                displayName: "Samsung TV",
                modelName: samsung.modelName,
                firmwareVersion: nil,
                lastKnownAddress: samsung.address.rawValue
            ))
        context.insert(
            SavedTV(
                brand: .vizio,
                reportedDeviceID: vizio.reportedDeviceID,
                displayName: "Vizio TV",
                modelName: vizio.modelName,
                firmwareVersion: nil,
                lastKnownAddress: vizio.address.rawValue,
                controlPort: vizio.controlPort
            ))
        try context.save()

        let savedTVs = try context.fetch(FetchDescriptor<SavedTV>())
        #expect(
            Set(savedTVs.map(\.stableDeviceKey)) == Set([samsung.stableDeviceKey, vizio.stableDeviceKey]))
    }

    @Test("Samsung wake requires an explicitly wireless connection")
    func scopesSamsungWakeToConfirmedWirelessConnections() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let unavailable = ConnectedTV(
            brand: .samsung,
            reportedDeviceID: "synthetic-device-id",
            address: address,
            modelName: "Q70AA",
            firmwareVersion: nil,
            networkConnection: .unavailable,
            macAddress: try TVMACAddress("02:00:5E:10:00:01")
        )
        let wireless = ConnectedTV(
            brand: .samsung,
            reportedDeviceID: "synthetic-device-id",
            address: address,
            modelName: "Q70AA",
            firmwareVersion: nil,
            networkConnection: .wireless,
            macAddress: try TVMACAddress("02:00:5E:10:00:01")
        )
        let otherBrand = ConnectedTV(
            brand: .vizio,
            reportedDeviceID: "synthetic-device-id",
            address: address,
            modelName: "V-Series",
            firmwareVersion: nil,
            networkConnection: .wireless,
            macAddress: try TVMACAddress("02:00:5E:10:00:01")
        )

        #expect(!unavailable.isEligibleForSamsungWake)
        #expect(wireless.isEligibleForSamsungWake)
        #expect(!otherBrand.isEligibleForSamsungWake)
    }

    @Test("A pending wake only matches the same brand-scoped TV identity")
    func scopesPendingWakeByStableDeviceKey() throws {
        let address = try PrivateIPv4Address("192.168.10.20")
        let samsung = ConnectedTV(
            brand: .samsung,
            reportedDeviceID: "shared-device-id",
            address: address,
            modelName: "Q70AA",
            firmwareVersion: nil,
            networkConnection: .wireless
        )
        let vizio = ConnectedTV(
            brand: .vizio,
            reportedDeviceID: "shared-device-id",
            address: address,
            modelName: "V-Series",
            firmwareVersion: nil,
            networkConnection: .wireless
        )
        let attempt = PendingWakeAttempt(stableDeviceKey: samsung.stableDeviceKey)

        #expect(attempt.matches(samsung))
        #expect(!attempt.matches(vizio))
    }

    @Test("An invalid persisted host is never reused for a connection")
    func rejectsInvalidPersistedAddress() {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "TV",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "example.com"
        )

        #expect(saved.validatedAddress == nil)
    }

    @Test("A stable device identifier preserves metadata across DHCP changes")
    func updatesAddressWithoutReplacingSavedTV() throws {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            roomName: "Main House",
            modelName: "Q70AA",
            firmwareVersion: "1001",
            lastKnownAddress: "192.168.10.20"
        )
        let reconnectedTV = PairedSamsungTV(
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.42"),
            modelName: "Q70AA",
            firmwareVersion: "1002",
            networkConnection: .wireless,
            macAddress: try SamsungMACAddress("02:00:5E:10:00:02")
        )

        saved.recordConnection(to: reconnectedTV, at: Date(timeIntervalSince1970: 300))

        #expect(saved.displayName == "Living Room")
        #expect(saved.roomName == "Main House")
        #expect(saved.reportedDeviceID == "synthetic-device-id")
        #expect(saved.lastKnownAddress == "192.168.10.42")
        #expect(saved.firmwareVersion == "1002")
        #expect(saved.macAddress == "02:00:5E:10:00:02")
        #expect(saved.lastUsedAt == Date(timeIntervalSince1970: 300))
    }

    /// Removing a selected record promotes the requested remaining record.
    @MainActor
    @Test("Removing the selected TV chooses the requested local fallback")
    func replacesRemovedSelection() {
        let selection = SavedTVSelectionCoordinator()
        selection.selectWithoutConnecting("sony:first")

        selection.removeSelection(
            for: "sony:first",
            replacementDeviceKey: "samsung:second"
        )

        #expect(selection.selectedDeviceKey == "samsung:second")
        #expect(!selection.isSwitching)
    }

    /// Control characters never survive into display names or reconnect targets.
    @Test("Connected TVs keep a safe bounded display name from discovery")
    func sanitizesConnectedDisplayName() throws {
        let television = ConnectedTV(
            brand: .vizio,
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.20"),
            controlPort: 7345,
            displayName: "  Den\u{0000} TV  ",
            modelName: "V-Series",
            firmwareVersion: nil
        )

        #expect(television.displayName == "Den TV")
        #expect(television.connectionTarget.suggestedDisplayName == "Den TV")
    }

    /// A persisted pending deletion is completed after constructing a fresh model context.
    @MainActor
    @Test("Pending TV removal resumes across model contexts")
    func pendingRemovalResumesAcrossModelContexts() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedTV.self, configurations: configuration)
        let originalContext = container.mainContext
        let pendingTV = SavedTV(
            brand: .vizio,
            reportedDeviceID: "recovery-tv",
            displayName: "Den TV",
            roomName: "Den",
            modelName: "V-Series",
            firmwareVersion: "9.0",
            lastKnownAddress: "192.168.10.40",
            controlPort: 7345,
            macAddress: "02:00:5E:10:00:09",
            wakeWasVerified: true,
            pendingCredentialRemoval: true,
            lastSeenAt: Date(timeIntervalSince1970: 400),
            lastUsedAt: Date(timeIntervalSince1970: 500)
        )
        originalContext.insert(pendingTV)
        try originalContext.save()

        let recoveryContext = ModelContext(container)
        let records = try recoveryContext.fetch(FetchDescriptor<SavedTV>())
        var removedDeviceIDs: [String] = []
        let succeeded = await SavedTVPendingRemovalRecovery.reconcile(
            records,
            in: recoveryContext
        ) { savedTV in
            removedDeviceIDs.append(savedTV.reportedDeviceID)
        }

        let verificationContext = ModelContext(container)
        #expect(succeeded)
        #expect(removedDeviceIDs == ["recovery-tv"])
        #expect(try verificationContext.fetch(FetchDescriptor<SavedTV>()).isEmpty)
    }

    /// Failed reconciliation keeps the durable marker so the UI can offer a retry.
    @MainActor
    @Test("Failed pending TV removal remains retryable")
    func failedPendingRemovalRemainsRetryable() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedTV.self, configurations: configuration)
        let originalContext = container.mainContext
        originalContext.insert(
            SavedTV(
                brand: .sony,
                reportedDeviceID: "pending-sony",
                displayName: "Bedroom TV",
                modelName: "BRAVIA",
                firmwareVersion: nil,
                lastKnownAddress: "192.168.10.41",
                pendingCredentialRemoval: true
            )
        )
        try originalContext.save()

        let recoveryContext = ModelContext(container)
        let records = try recoveryContext.fetch(FetchDescriptor<SavedTV>())
        let succeeded = await SavedTVPendingRemovalRecovery.reconcile(
            records,
            in: recoveryContext
        ) { _ in
            throw SyntheticSavedTVRemovalError.failed
        }

        let verificationContext = ModelContext(container)
        let remaining = try #require(
            verificationContext.fetch(FetchDescriptor<SavedTV>()).first
        )
        #expect(!succeeded)
        #expect(remaining.reportedDeviceID == "pending-sony")
        #expect(remaining.pendingCredentialRemoval)
    }

    @Test("A reconnect without wake metadata preserves the previously captured MAC")
    func preservesMACWhenReconnectOmitsIt() throws {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20",
            macAddress: "02:00:5E:10:00:01"
        )
        let reconnectedTV = PairedSamsungTV(
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.42"),
            modelName: "Q70AA",
            firmwareVersion: nil
        )

        saved.recordConnection(to: reconnectedTV)

        #expect(saved.macAddress == "02:00:5E:10:00:01")
    }

    @Test("A changed wireless MAC invalidates prior wake verification")
    func invalidatesWakeVerificationWhenWirelessMACChanges() throws {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20",
            macAddress: "02:00:5E:10:00:01",
            wakeWasVerified: true
        )
        let reconnectedTV = PairedSamsungTV(
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.42"),
            modelName: "Q70AA",
            firmwareVersion: nil,
            networkConnection: .wireless,
            macAddress: try SamsungMACAddress("02:00:5E:10:00:02")
        )

        saved.recordConnection(to: reconnectedTV, wakeWasJustVerified: true)

        #expect(saved.macAddress == "02:00:5E:10:00:02")
        #expect(!saved.wakeWasVerified)
    }

    @Test("A successful wireless wake verifies the unchanged target MAC")
    func verifiesSuccessfulWakeForUnchangedWirelessMAC() throws {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20",
            macAddress: "02:00:5E:10:00:01"
        )
        let reconnectedTV = PairedSamsungTV(
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.20"),
            modelName: "Q70AA",
            firmwareVersion: nil,
            networkConnection: .wireless,
            macAddress: try SamsungMACAddress("02:00:5E:10:00:01")
        )

        saved.recordConnection(to: reconnectedTV, wakeWasJustVerified: true)

        #expect(saved.macAddress == "02:00:5E:10:00:01")
        #expect(saved.wakeWasVerified)
    }

    @Test("A wireless reconnect without a reported MAC does not verify a wake target")
    func doesNotVerifyWakeWithoutReportedWirelessMAC() throws {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20",
            macAddress: "02:00:5E:10:00:01"
        )
        let reconnectedTV = PairedSamsungTV(
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.20"),
            modelName: "Q70AA",
            firmwareVersion: nil,
            networkConnection: .wireless
        )

        saved.recordConnection(to: reconnectedTV, wakeWasJustVerified: true)

        #expect(saved.macAddress == "02:00:5E:10:00:01")
        #expect(!saved.wakeWasVerified)
    }

    @Test("An explicit wired reconnect clears stale wireless wake metadata")
    func clearsMACWhenReconnectIsWired() throws {
        let saved = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20",
            macAddress: "02:00:5E:10:00:01",
            wakeWasVerified: true
        )
        let reconnectedTV = PairedSamsungTV(
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.42"),
            modelName: "Q70AA",
            firmwareVersion: nil,
            networkConnection: .wired
        )

        saved.recordConnection(to: reconnectedTV, wakeWasJustVerified: true)

        #expect(saved.macAddress == nil)
        #expect(!saved.wakeWasVerified)
    }

    @MainActor
    @Test("An empty initial query retries when saved TVs populate")
    func retriesRestorationWhenSavedTVsPopulate() async {
        let restoration = SavedTVRestorationCoordinator()
        var connectionAttempts = 0
        let newlyPairedTV = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20"
        )

        await restoration.restore(from: []) { _ in
            connectionAttempts += 1
        }
        await restoration.restore(from: [newlyPairedTV]) { _ in
            connectionAttempts += 1
        }

        #expect(connectionAttempts == 1)
        #expect(!restoration.isRestoring)
    }

    @MainActor
    @Test("A connected first pairing is not restored when its saved record appears")
    func doesNotRestoreNewlyPairedTV() async {
        let restoration = SavedTVRestorationCoordinator()
        let newlyPairedTV = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20"
        )
        var connectionAttempts = 0

        await restoration.restore(from: []) { _ in
            connectionAttempts += 1
        }
        await restoration.restore(
            from: [newlyPairedTV],
            skipBecauseConnectionWasInitiated: true
        ) { _ in
            connectionAttempts += 1
        }

        #expect(connectionAttempts == 0)
        #expect(!restoration.isRestoring)
    }

    @MainActor
    @Test("A valid saved TV restores exactly once and exposes progress")
    func restoresValidSavedTVExactlyOnce() async {
        let restoration = SavedTVRestorationCoordinator()
        let gate = RestorationConnectionGate()
        let savedTV = SavedTV(
            brand: .sony,
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Sony BRAVIA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20",
            controlPort: 6466
        )
        let task = Task { @MainActor in
            await restoration.restore(from: [savedTV]) { target in
                await gate.wait(at: target)
            }
        }

        let target = await gate.nextTarget()
        #expect(target?.address == (try? PrivateIPv4Address("192.168.10.20")))
        #expect(target?.brand == .sony)
        #expect(target?.reportedDeviceID == "synthetic-device-id")
        #expect(target?.controlPort == 6466)
        #expect(restoration.isRestoring)

        await gate.resume()
        await task.value
        #expect(!restoration.isRestoring)

        await restoration.restore(from: [savedTV]) { _ in
            Issue.record("The one-shot restoration attempted a second connection")
        }
        #expect(await gate.connectionCount == 1)
    }

    @MainActor
    @Test("A failed saved TV connection clears restoration progress")
    func clearsProgressAfterFailure() async {
        let restoration = SavedTVRestorationCoordinator()
        let savedTV = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20"
        )

        await restoration.restore(from: [savedTV]) { _ in
            throw RestorationTestError.failed
        }

        #expect(!restoration.isRestoring)
    }

    @MainActor
    @Test("Cancelling saved TV restoration clears progress")
    func clearsProgressAfterCancellation() async {
        let restoration = SavedTVRestorationCoordinator()
        let gate = RestorationConnectionGate()
        let savedTV = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20"
        )
        let task = Task { @MainActor in
            await restoration.restore(from: [savedTV]) { target in
                await gate.waitUntilCancelled(at: target)
            }
        }

        _ = await gate.nextTarget()
        #expect(restoration.isRestoring)
        task.cancel()
        await task.value

        #expect(!restoration.isRestoring)
    }

    @Test("Pairing restoration tells the user to approve on the TV")
    func explainsPairingRestoration() {
        let pairing = SavedTVRestorationPresentation(state: .pairing)
        let connecting = SavedTVRestorationPresentation(state: .connecting)

        #expect(pairing.title == "Approve Hafa Remote on your TV")
        #expect(pairing.instruction == "Follow the approval prompt on your TV to finish connecting.")
        #expect(connecting.title == "Connecting to your TV…")
        #expect(connecting.instruction == nil)
    }

    @Test("A saved TV can present its identity while it is offline")
    func buildsOfflinePresentationFromSavedMetadata() throws {
        let savedTV = SavedTV(
            brand: .vizio,
            reportedDeviceID: "synthetic-vizio",
            displayName: "Office TV",
            modelName: "V655-G9",
            firmwareVersion: "1.2.3",
            lastKnownAddress: "192.168.10.30",
            controlPort: 7_345
        )

        let rememberedTV = try #require(savedTV.rememberedTV)

        #expect(rememberedTV.brand == .vizio)
        #expect(rememberedTV.reportedDeviceID == "synthetic-vizio")
        #expect(rememberedTV.address == (try PrivateIPv4Address("192.168.10.30")))
        #expect(rememberedTV.controlPort == 7_345)
        #expect(rememberedTV.modelName == "V655-G9")
        #expect(rememberedTV.networkConnection == .unavailable)
    }

    @MainActor
    @Test("Selecting another TV immediately changes identity and cancels the stale switch")
    func latestTVSelectionWins() async throws {
        let selection = SavedTVSelectionCoordinator()
        let gate = SelectionCancellationGate()
        let first = TVConnectionTarget(
            brand: .samsung,
            reportedDeviceID: "first",
            address: try PrivateIPv4Address("192.168.10.20"),
            controlPort: 8_002
        )
        let second = TVConnectionTarget(
            brand: .sony,
            reportedDeviceID: "second",
            address: try PrivateIPv4Address("192.168.10.21"),
            controlPort: 6_466
        )
        var connectedTargets: [TVConnectionTarget] = []

        selection.select(
            deviceKey: "samsung:first",
            target: first,
            disconnect: {
                await gate.suspendUntilCancelled()
            },
            connect: { connectedTargets.append($0) }
        )
        #expect(selection.selectedDeviceKey == "samsung:first")
        await waitForSelectionState { await gate.didStart }
        #expect(await gate.didStart)

        selection.select(
            deviceKey: "sony:second",
            target: second,
            disconnect: {},
            connect: { connectedTargets.append($0) }
        )

        await waitForSelectionState { await gate.didFinish }
        await waitForSelectionState { connectedTargets == [second] && !selection.isSwitching }
        #expect(await gate.didFinish)
        #expect(connectedTargets == [second])
        #expect(selection.selectedDeviceKey == "sony:second")
        #expect(!selection.isSwitching)
    }

    @MainActor
    @Test(
        "Saved-TV rediscovery binds candidate aliases to the remembered identity",
        arguments: [TVBrand.sony, .vizio])
    func recoveryKeepsSavedIdentityWhenAliasDiffers(brand: TVBrand) async throws {
        let port: UInt16 = brand == .sony ? 6466 : 7345
        let alias = "synthetic-discovery-alias"
        let savedIdentity = "synthetic-authenticated-identity"
        let cached = TVConnectionTarget(
            brand: brand,
            reportedDeviceID: savedIdentity,
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.45"),
            controlPort: port,
            expectedSavedDeviceID: savedIdentity,
            discoveryIdentifier: alias
        )
        let moved = DiscoveredTV(
            brand: brand,
            reportedIdentifier: alias,
            displayName: "Synthetic Office TV",
            modelName: "Synthetic Model",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.46"),
            controlPort: port
        )
        let recovery = SavedTVAddressRecoveryCoordinator(
            discovery: TVDiscoveryStore(
                backend: SavedTVRecoveryDiscoveryBackend(events: [.found(moved), .finished])
            ))
        var connectedTargets: [TVConnectionTarget] = []
        recovery.recover(stableDeviceKey: "\(brand.rawValue):\(savedIdentity)", cachedTarget: cached) {
            connectedTargets.append($0)
        }
        await waitForSelectionState { !recovery.isRecovering }

        #expect(connectedTargets == [moved.connectionTarget.expectingSavedIdentity(savedIdentity)])
        #expect(connectedTargets.first?.reportedDeviceID == alias)
        #expect(connectedTargets.first?.expectedSavedDeviceID == savedIdentity)
    }

    @MainActor
    @Test("Recovery does not retry the same endpoint when only candidate metadata differs")
    func recoveryDoesNotLoopOnAliasCollisionAtCachedAddress() async throws {
        let address = try PrivateIPv4Address(documentationAddressForTesting: "198.51.100.45")
        let alias = "synthetic-colliding-alias"
        let cached = TVConnectionTarget(
            brand: .sony,
            reportedDeviceID: "synthetic-authenticated-identity",
            address: address,
            controlPort: 6466,
            expectedSavedDeviceID: "synthetic-authenticated-identity",
            discoveryIdentifier: alias
        )
        let candidate = DiscoveredTV(
            brand: .sony,
            reportedIdentifier: alias,
            displayName: "Synthetic Other Name",
            modelName: "Synthetic Other Model",
            address: address,
            controlPort: 6466
        )
        let recovery = SavedTVAddressRecoveryCoordinator(
            discovery: TVDiscoveryStore(
                backend: SavedTVRecoveryDiscoveryBackend(events: [.found(candidate), .finished])
            ))
        var connections = 0
        recovery.recover(stableDeviceKey: "sony:synthetic-authenticated-identity", cachedTarget: cached) {
            _ in
            connections += 1
        }
        await waitForSelectionState { !recovery.isRecovering }
        #expect(connections == 0)
    }

    @MainActor
    @Test("Saved-TV recovery reconnects only when discovery finds the same TV at a new endpoint")
    func savedTVRecoveryFollowsStableIdentity() async throws {
        let cached = TVConnectionTarget(
            brand: .vizio,
            reportedDeviceID: "saved-vizio",
            address: try PrivateIPv4Address("192.168.10.30"),
            controlPort: 7_345
        )
        let moved = DiscoveredTV(
            brand: .vizio,
            reportedIdentifier: "saved-vizio",
            displayName: "Office TV",
            modelName: "SmartCast",
            address: try PrivateIPv4Address("192.168.10.44"),
            controlPort: 7_345
        )
        let backend = SavedTVRecoveryDiscoveryBackend(events: [.found(moved), .finished])
        let recovery = SavedTVAddressRecoveryCoordinator(
            discovery: TVDiscoveryStore(backend: backend, searchDuration: .milliseconds(50))
        )
        var connectedTargets: [TVConnectionTarget] = []

        recovery.recover(stableDeviceKey: "vizio:saved-vizio", cachedTarget: cached) {
            connectedTargets.append($0)
        }

        await waitForSelectionState { connectedTargets == [moved.connectionTarget] }
        #expect(connectedTargets == [moved.connectionTarget])
        #expect(!recovery.isRecovering)
    }

    @MainActor
    @Test("Cancelling saved-TV recovery stops discovery and cannot reconnect later")
    func cancellingSavedTVRecoveryPreventsConnection() async throws {
        let cached = TVConnectionTarget(
            brand: .samsung,
            reportedDeviceID: "saved-samsung",
            address: try PrivateIPv4Address("192.168.10.30"),
            controlPort: 8_002
        )
        let backend = PendingSavedTVRecoveryDiscoveryBackend()
        let recovery = SavedTVAddressRecoveryCoordinator(
            discovery: TVDiscoveryStore(backend: backend, searchDuration: .seconds(30))
        )
        var connectedTargets: [TVConnectionTarget] = []
        recovery.recover(stableDeviceKey: "samsung:saved-samsung", cachedTarget: cached) {
            connectedTargets.append($0)
        }
        await backend.waitUntilStarted()

        recovery.cancel()
        backend.emit(
            .found(
                DiscoveredTV(
                    reportedIdentifier: "saved-samsung",
                    displayName: "Living Room TV",
                    modelName: "Samsung TV",
                    address: try PrivateIPv4Address("192.168.10.31")
                )
            )
        )
        await Task.yield()

        #expect(!recovery.isRecovering)
        #expect(backend.stopCount >= 1)
        #expect(connectedTargets.isEmpty)
    }
}

private enum RestorationTestError: Error {
    case failed
}

@MainActor
private final class SavedTVRecoveryDiscoveryBackend: TVDiscoveryBackend {
    private let events: [TVDiscoveryBackendEvent]

    init(events: [TVDiscoveryBackendEvent]) {
        self.events = events
    }

    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    ) {
        events.forEach(eventHandler)
    }

    func stop() {}
}

@MainActor
private final class PendingSavedTVRecoveryDiscoveryBackend: TVDiscoveryBackend {
    private var eventHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?
    private(set) var stopCount = 0
    private var startCount = 0

    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    ) {
        startCount += 1
        self.eventHandler = eventHandler
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ event: TVDiscoveryBackendEvent) {
        eventHandler?(event)
    }

    func waitUntilStarted() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while startCount == 0, clock.now < deadline {
            await Task.yield()
        }
        #expect(startCount == 1)
    }
}

private actor SelectionCancellationGate {
    private(set) var didStart = false
    private(set) var didFinish = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendUntilCancelled() async {
        didStart = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    didFinish = true
                    continuation.resume()
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.finish() }
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitForSelectionState(_ condition: @escaping @MainActor () async -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for the expected selection state")
}

private enum SyntheticSavedTVRemovalError: Error {
    case failed
}

private actor RestorationConnectionGate {
    private var count = 0
    private let targets: AsyncStream<TVConnectionTarget>
    private let targetContinuation: AsyncStream<TVConnectionTarget>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init() {
        (targets, targetContinuation) = AsyncStream.makeStream()
    }

    var connectionCount: Int { count }

    func nextTarget() async -> TVConnectionTarget? {
        var iterator = targets.makeAsyncIterator()
        return await iterator.next()
    }

    func wait(at target: TVConnectionTarget) async {
        count += 1
        targetContinuation.yield(target)
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilCancelled(at target: TVConnectionTarget) async {
        count += 1
        targetContinuation.yield(target)
        try? await Task.sleep(for: .seconds(30))
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
