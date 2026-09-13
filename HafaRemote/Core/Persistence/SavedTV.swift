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
    var roomName: String?
    var modelName: String
    var firmwareVersion: String?
    var lastKnownAddress: String
    var controlPort: Int?
    var macAddress: String?
    var wakeWasVerified: Bool = false
    var pendingCredentialRemoval: Bool = false
    /// Comma-separated raw values keep the additive SwiftData migration inspectable.
    var capabilitiesRawValue: String = ""
    var lastSeenAt: Date
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        brand: TVBrand = .samsung,
        reportedDeviceID: String,
        displayName: String,
        roomName: String? = nil,
        modelName: String,
        firmwareVersion: String?,
        lastKnownAddress: String,
        controlPort: UInt16? = nil,
        macAddress: String? = nil,
        wakeWasVerified: Bool = false,
        pendingCredentialRemoval: Bool = false,
        capabilities: Set<TVCapability>? = nil,
        lastSeenAt: Date = .now,
        lastUsedAt: Date = .now
    ) {
        self.id = id
        brandRawValue = brand.rawValue
        stableDeviceID = "\(brand.rawValue):\(reportedDeviceID)"
        self.reportedDeviceID = reportedDeviceID
        self.displayName = displayName
        self.roomName = roomName
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.lastKnownAddress = lastKnownAddress
        self.controlPort = controlPort.map(Int.init)
        self.macAddress = macAddress
        self.wakeWasVerified = wakeWasVerified
        self.pendingCredentialRemoval = pendingCredentialRemoval
        capabilitiesRawValue = Self.encodeCapabilities(
            capabilities ?? Self.defaultCapabilities(for: brand, macAddress: macAddress)
        )
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

    var capabilities: Set<TVCapability> {
        let decoded = Set(
            capabilitiesRawValue.split(separator: ",").compactMap {
                TVCapability(rawValue: String($0))
            }
        )
        return decoded.isEmpty
            ? Self.defaultCapabilities(for: brand, macAddress: macAddress) : decoded
    }

    var validatedControlPort: UInt16? {
        guard let controlPort, controlPort > 0 else { return nil }
        return UInt16(exactly: controlPort)
    }

    var connectionTarget: TVConnectionTarget? {
        guard let address = validatedAddress else { return nil }
        return TVConnectionTarget(
            brand: brand,
            reportedDeviceID: reportedDeviceID,
            address: address,
            controlPort: validatedControlPort,
            suggestedDisplayName: displayName
        )
    }

    /// A non-connected presentation of this saved TV for the remote screen.
    /// Command availability must still be derived from the active session identity.
    var rememberedTV: ConnectedTV? {
        guard let address = validatedAddress else { return nil }
        let savedMACAddress = validatedMACAddress
        return ConnectedTV(
            brand: brand,
            reportedDeviceID: reportedDeviceID,
            address: address,
            controlPort: validatedControlPort,
            displayName: displayName,
            modelName: modelName,
            firmwareVersion: firmwareVersion,
            networkConnection: savedMACAddress == nil ? .unavailable : .wireless,
            macAddress: savedMACAddress,
            capabilities: capabilities
        )
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
        capabilitiesRawValue = Self.encodeCapabilities(tv.capabilities)
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

    private static func encodeCapabilities(_ capabilities: Set<TVCapability>) -> String {
        capabilities.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func defaultCapabilities(
        for brand: TVBrand,
        macAddress: String?
    ) -> Set<TVCapability> {
        var capabilities = TVCapability.implemented(for: brand)
        if brand == .samsung,
            let macAddress,
            (try? TVMACAddress(macAddress)) != nil
        {
            capabilities.insert(.powerOn)
        }
        return capabilities
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
