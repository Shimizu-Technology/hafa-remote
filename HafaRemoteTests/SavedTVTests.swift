import Foundation
import SwiftData
import Testing

@testable import HafaRemote

struct SavedTVTests {
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
            modelName: "Q70AA",
            firmwareVersion: "2210",
            lastKnownAddress: "192.168.10.20",
            controlPort: 6466,
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
        #expect(fetched.first?.modelName == "Q70AA")
        #expect(fetched.first?.firmwareVersion == "2210")
        #expect(fetched.first?.validatedAddress == (try PrivateIPv4Address("192.168.10.20")))
        #expect(fetched.first?.validatedControlPort == 6466)
        #expect(fetched.first?.validatedMACAddress == (try SamsungMACAddress("02:00:5E:10:00:01")))
        #expect(fetched.first?.wakeWasVerified == true)
        #expect(fetched.first?.lastSeenAt == Date(timeIntervalSince1970: 100))
        #expect(fetched.first?.lastUsedAt == Date(timeIntervalSince1970: 200))
        #expect(fetched.first?.description == "SavedTV(redacted)")
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
        #expect(saved.reportedDeviceID == "synthetic-device-id")
        #expect(saved.lastKnownAddress == "192.168.10.42")
        #expect(saved.firmwareVersion == "1002")
        #expect(saved.macAddress == "02:00:5E:10:00:02")
        #expect(saved.lastUsedAt == Date(timeIntervalSince1970: 300))
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
    @Test("An empty initial restore is not retried after the first TV is paired")
    func doesNotRestoreAgainWhenSavedTVsPopulate() async {
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
                try? await Task.sleep(for: .seconds(30))
            },
            connect: { connectedTargets.append($0) }
        )
        #expect(selection.selectedDeviceKey == "samsung:first")

        selection.select(
            deviceKey: "sony:second",
            target: second,
            disconnect: {},
            connect: { connectedTargets.append($0) }
        )

        for _ in 0..<100 where connectedTargets != [second] {
            await Task.yield()
        }
        #expect(selection.selectedDeviceKey == "sony:second")
        #expect(!selection.isSwitching)
    }
}

private enum RestorationTestError: Error {
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
