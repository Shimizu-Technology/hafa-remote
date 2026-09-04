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
            displayName: "TV",
            modelName: "Q70AA",
            firmwareVersion: nil,
            lastKnownAddress: "example.com"
        )

        #expect(saved.validatedAddress == nil)
    }
}
