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
            firmwareVersion: "1002"
        )

        saved.recordConnection(to: reconnectedTV, at: Date(timeIntervalSince1970: 300))

        #expect(saved.displayName == "Living Room")
        #expect(saved.reportedDeviceID == "synthetic-device-id")
        #expect(saved.lastKnownAddress == "192.168.10.42")
        #expect(saved.firmwareVersion == "1002")
        #expect(saved.lastUsedAt == Date(timeIntervalSince1970: 300))
    }

    @Test("An empty initial restore is not retried after the first TV is paired")
    func doesNotRestoreAgainWhenSavedTVsPopulate() {
        var gate = InitialSavedTVRestoreGate()

        #expect(gate.claimAddress(from: []) == nil)

        let newlyPairedTV = SavedTV(
            reportedDeviceID: "synthetic-device-id",
            displayName: "Living Room",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "192.168.10.20"
        )

        #expect(gate.claimAddress(from: [newlyPairedTV]) == nil)
        #expect(gate.didAttempt)
    }
}
