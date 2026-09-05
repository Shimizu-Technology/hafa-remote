import Foundation
import SwiftData

/// Non-secret metadata needed to restore a previously approved television.
@Model
final class SavedTV: CustomStringConvertible {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var reportedDeviceID: String
    var displayName: String
    var modelName: String
    var firmwareVersion: String?
    var lastKnownAddress: String
    var lastSeenAt: Date
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        reportedDeviceID: String,
        displayName: String,
        modelName: String,
        firmwareVersion: String?,
        lastKnownAddress: String,
        lastSeenAt: Date = .now,
        lastUsedAt: Date = .now
    ) {
        self.id = id
        self.reportedDeviceID = reportedDeviceID
        self.displayName = displayName
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.lastKnownAddress = lastKnownAddress
        self.lastSeenAt = lastSeenAt
        self.lastUsedAt = lastUsedAt
    }

    var validatedAddress: PrivateIPv4Address? {
        try? PrivateIPv4Address(lastKnownAddress)
    }

    var description: String {
        "SavedTV(redacted)"
    }

    func recordConnection(to tv: PairedSamsungTV, at date: Date = .now) {
        reportedDeviceID = tv.reportedDeviceID
        modelName = tv.modelName
        firmwareVersion = tv.firmwareVersion
        lastKnownAddress = tv.address.rawValue
        lastSeenAt = date
        lastUsedAt = date
    }
}
