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
    var macAddress: String?
    var wakeWasVerified: Bool = false
    var lastSeenAt: Date
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        reportedDeviceID: String,
        displayName: String,
        modelName: String,
        firmwareVersion: String?,
        lastKnownAddress: String,
        macAddress: String? = nil,
        wakeWasVerified: Bool = false,
        lastSeenAt: Date = .now,
        lastUsedAt: Date = .now
    ) {
        self.id = id
        self.reportedDeviceID = reportedDeviceID
        self.displayName = displayName
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.lastKnownAddress = lastKnownAddress
        self.macAddress = macAddress
        self.wakeWasVerified = wakeWasVerified
        self.lastSeenAt = lastSeenAt
        self.lastUsedAt = lastUsedAt
    }

    var validatedAddress: PrivateIPv4Address? {
        try? PrivateIPv4Address(lastKnownAddress)
    }

    var validatedMACAddress: SamsungMACAddress? {
        macAddress.flatMap { try? SamsungMACAddress($0) }
    }

    var description: String {
        "SavedTV(redacted)"
    }

    func recordConnection(
        to tv: PairedSamsungTV,
        at date: Date = .now,
        wakeWasJustVerified: Bool = false
    ) {
        reportedDeviceID = tv.reportedDeviceID
        modelName = tv.modelName
        firmwareVersion = tv.firmwareVersion
        lastKnownAddress = tv.address.rawValue
        let previousMACAddress = macAddress
        switch tv.networkConnection {
        case .wired:
            macAddress = nil
            wakeWasVerified = false
        case .wireless:
            if let macAddress = tv.macAddress {
                let incomingMACAddress = macAddress.persistedValue
                if self.macAddress != incomingMACAddress {
                    wakeWasVerified = false
                    self.macAddress = incomingMACAddress
                }
            }
            let reportedMACAddress = tv.macAddress?.persistedValue
            if wakeWasJustVerified,
                macAddress != nil,
                reportedMACAddress == nil || reportedMACAddress == previousMACAddress
            {
                wakeWasVerified = true
            }
        case .unavailable:
            break
        }
        lastSeenAt = date
        lastUsedAt = date
    }
}
