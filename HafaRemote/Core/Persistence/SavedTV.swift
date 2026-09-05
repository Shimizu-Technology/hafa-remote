import Foundation
import SwiftData

/// Non-secret metadata needed to restore a previously approved television.
@Model
final class SavedTV: CustomStringConvertible {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var stableDeviceID: String?
    var reportedDeviceID: String
    var brandRawValue: String = TVBrand.samsung.rawValue
    var displayName: String
    var modelName: String
    var firmwareVersion: String?
    var lastKnownAddress: String
    var controlPort: Int?
    var macAddress: String?
    var wakeWasVerified: Bool = false
    var lastSeenAt: Date
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        brand: TVBrand = .samsung,
        reportedDeviceID: String,
        displayName: String,
        modelName: String,
        firmwareVersion: String?,
        lastKnownAddress: String,
        controlPort: UInt16? = nil,
        macAddress: String? = nil,
        wakeWasVerified: Bool = false,
        lastSeenAt: Date = .now,
        lastUsedAt: Date = .now
    ) {
        self.id = id
        brandRawValue = brand.rawValue
        stableDeviceID = "\(brand.rawValue):\(reportedDeviceID)"
        self.reportedDeviceID = reportedDeviceID
        self.displayName = displayName
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.lastKnownAddress = lastKnownAddress
        self.controlPort = controlPort.map(Int.init)
        self.macAddress = macAddress
        self.wakeWasVerified = wakeWasVerified
        self.lastSeenAt = lastSeenAt
        self.lastUsedAt = lastUsedAt
    }

    var validatedAddress: PrivateIPv4Address? {
        try? PrivateIPv4Address(lastKnownAddress)
    }

    var brand: TVBrand {
        TVBrand(rawValue: brandRawValue) ?? .samsung
    }

    var stableDeviceKey: String {
        stableDeviceID ?? "\(brand.rawValue):\(reportedDeviceID)"
    }

    var validatedControlPort: UInt16? {
        guard let controlPort, controlPort > 0 else { return nil }
        return UInt16(exactly: controlPort)
    }

    var validatedMACAddress: TVMACAddress? {
        macAddress.flatMap { try? TVMACAddress($0) }
    }

    var description: String {
        "SavedTV(redacted)"
    }

    /// Persists the identity fields added after the Samsung-only internal alpha.
    func backfillLegacyIdentityIfNeeded() {
        let resolvedBrand = brand
        brandRawValue = resolvedBrand.rawValue
        if stableDeviceID == nil {
            stableDeviceID = "\(resolvedBrand.rawValue):\(reportedDeviceID)"
        }
    }

    func recordConnection(
        to tv: ConnectedTV,
        at date: Date = .now,
        wakeWasJustVerified: Bool = false
    ) {
        brandRawValue = tv.brand.rawValue
        stableDeviceID = tv.stableDeviceKey
        reportedDeviceID = tv.reportedDeviceID
        modelName = tv.modelName
        firmwareVersion = tv.firmwareVersion
        lastKnownAddress = tv.address.rawValue
        controlPort = tv.controlPort.map(Int.init)
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
                let reportedMACAddress,
                let previousMACAddress,
                reportedMACAddress == previousMACAddress
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

/// Repairs internal-alpha records before later code relies on stable identity uniqueness.
@MainActor
enum SavedTVLegacyIdentityMigration {
    @discardableResult
    static func apply(to records: [SavedTV], in context: ModelContext) -> Bool {
        var changed = false
        let groups = Dictionary(grouping: records, by: \.stableDeviceKey)

        for recordsWithSameIdentity in groups.values {
            let ordered = recordsWithSameIdentity.sorted(by: preferredSurvivor)
            guard let survivor = ordered.first else { continue }

            for duplicate in ordered.dropFirst() {
                context.delete(duplicate)
                changed = true
            }
            if survivor.stableDeviceID == nil {
                survivor.backfillLegacyIdentityIfNeeded()
                changed = true
            }
        }
        return changed
    }

    private static func preferredSurvivor(_ lhs: SavedTV, _ rhs: SavedTV) -> Bool {
        if (lhs.stableDeviceID != nil) != (rhs.stableDeviceID != nil) {
            return lhs.stableDeviceID != nil
        }
        if lhs.lastUsedAt != rhs.lastUsedAt {
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
