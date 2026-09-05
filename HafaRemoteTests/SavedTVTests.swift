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
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: "2210",
            lastKnownAddress: "192.168.10.20",
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
        #expect(fetched.first?.reportedDeviceID == "synthetic-device-id")
        #expect(fetched.first?.displayName == "Living Room")
        #expect(fetched.first?.modelName == "Q70AA")
        #expect(fetched.first?.firmwareVersion == "2210")
        #expect(fetched.first?.validatedAddress == (try PrivateIPv4Address("192.168.10.20")))
        #expect(fetched.first?.validatedMACAddress == (try SamsungMACAddress("02:00:5E:10:00:01")))
        #expect(fetched.first?.wakeWasVerified == true)
        #expect(fetched.first?.lastSeenAt == Date(timeIntervalSince1970: 100))
        #expect(fetched.first?.lastUsedAt == Date(timeIntervalSince1970: 200))
        #expect(fetched.first?.description == "SavedTV(redacted)")
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
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20"
        )
        let task = Task { @MainActor in
            await restoration.restore(from: [savedTV]) { address in
                await gate.wait(at: address)
            }
        }

        let address = await gate.nextAddress()
        #expect(address == (try? PrivateIPv4Address("192.168.10.20")))
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
            await restoration.restore(from: [savedTV]) { address in
                await gate.waitUntilCancelled(at: address)
            }
        }

        _ = await gate.nextAddress()
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
        #expect(pairing.instruction == "Choose Allow on the Samsung TV to finish connecting.")
        #expect(connecting.title == "Connecting to your TV…")
        #expect(connecting.instruction == nil)
    }
}

private enum RestorationTestError: Error {
    case failed
}

private actor RestorationConnectionGate {
    private var count = 0
    private let addresses: AsyncStream<PrivateIPv4Address>
    private let addressContinuation: AsyncStream<PrivateIPv4Address>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init() {
        (addresses, addressContinuation) = AsyncStream.makeStream()
    }

    var connectionCount: Int { count }

    func nextAddress() async -> PrivateIPv4Address? {
        var iterator = addresses.makeAsyncIterator()
        return await iterator.next()
    }

    func wait(at address: PrivateIPv4Address) async {
        count += 1
        addressContinuation.yield(address)
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilCancelled(at address: PrivateIPv4Address) async {
        count += 1
        addressContinuation.yield(address)
        try? await Task.sleep(for: .seconds(30))
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
