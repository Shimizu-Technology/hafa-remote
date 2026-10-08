import Foundation

enum TVBrand: String, Codable, CaseIterable, Hashable, Sendable {
    case samsung
    case sony
    case vizio

    var displayName: String {
        switch self {
        case .samsung:
            "Samsung"
        case .sony:
            "Sony"
        case .vizio:
            "Vizio"
        }
    }

    var defaultDeviceName: String {
        "\(displayName) TV"
    }
}

/// Brand-neutral features a connected television makes available to the app.
/// Presentation code consumes this set instead of guessing from a brand name.
enum TVCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case navigation
    case volume
    case mute
    case playback
    case textInput
    case powerOff
    case powerOn
    case sourceMenu
    case channels
    case guide
    case numberPad
    case favoriteApps
    case inputSelection

    static func implemented(for brand: TVBrand) -> Set<TVCapability> {
        var capabilities: Set<TVCapability> = [
            .navigation, .volume, .mute, .playback, .powerOff, .sourceMenu, .channels, .favoriteApps,
        ]
        switch brand {
        case .samsung:
            capabilities.formUnion([.textInput, .guide, .numberPad])
        case .sony:
            capabilities.formUnion([.powerOn, .textInput, .guide, .numberPad])
        case .vizio:
            capabilities.formUnion([.powerOn, .inputSelection])
        }
        return capabilities
    }
}

/// Screen power is observed separately from transport connectivity.
enum TVPowerState: String, Codable, Equatable, Sendable {
    case unknown
    case on
    case standby
}

struct TVCapabilityEvidence: Equatable, Sendable {
    let implemented: Set<TVCapability>
    let protocolReported: Set<TVCapability>?
    let hardwareVerified: Set<TVCapability>

    init(
        implemented: Set<TVCapability>,
        protocolReported: Set<TVCapability>? = nil,
        hardwareVerified: Set<TVCapability> = []
    ) {
        self.implemented = implemented
        self.protocolReported = protocolReported.map { $0.intersection(implemented) }
        self.hardwareVerified = hardwareVerified.intersection(implemented)
    }

    var internalAvailable: Set<TVCapability> {
        protocolReported.map { implemented.intersection($0) } ?? implemented
    }

    var publiclyAvailable: Set<TVCapability> {
        internalAvailable.intersection(hardwareVerified)
    }
}

/// Build exposure is separate from hardware evidence and permission to submit.
enum TVDistributionPolicy: Equatable, Sendable {
    case internalCandidate
    case publicRelease
    case unavailable

    static var current: Self {
        guard TVBuildFlavor.isConfigured else { return .unavailable }
        return TVBuildFlavor.compiled == .samsungPublic ? .publicRelease : .internalCandidate
    }

    var permittedBrands: [TVBrand] { TVBrand.allCases.filter(permits) }

    func permits(_ brand: TVBrand) -> Bool {
        switch self {
        case .unavailable: false
        case .publicRelease: brand == .samsung
        case .internalCandidate:
            TVBuildFlavor.compiled == .internalTesting || brand == .samsung
        }
    }
}

struct TVSessionObservation: Equatable, Sendable {
    let stableDeviceKey: String
    let powerState: TVPowerState
    let protocolReportedCapabilities: Set<TVCapability>?

    init(
        stableDeviceKey: String,
        powerState: TVPowerState,
        protocolReportedCapabilities: Set<TVCapability>? = nil
    ) {
        self.stableDeviceKey = stableDeviceKey
        self.powerState = powerState
        self.protocolReportedCapabilities = protocolReportedCapabilities
    }
}

/// One actor owns protocol observations; slow consumers receive only the newest value.
actor TVSessionObservationBroadcaster {
    private var current: TVSessionObservation?
    private var subscribers: [UUID: AsyncStream<TVSessionObservation>.Continuation] = [:]

    func stream() -> AsyncStream<TVSessionObservation> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TVSessionObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        if let current { continuation.yield(current) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    func snapshot() -> TVSessionObservation? { current }

    func publish(_ observation: TVSessionObservation) {
        current = observation
        for continuation in subscribers.values { continuation.yield(observation) }
    }

    func reset() {
        current = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}

extension RemoteCommand {
    var requiredCapability: TVCapability {
        switch self {
        case .powerOn: .powerOn
        case .powerOff: .powerOff
        case .up, .down, .left, .right, .select, .home, .back: .navigation
        case .volumeUp, .volumeDown: .volume
        case .mute: .mute
        case .play, .pause, .rewind, .fastForward: .playback
        case .inputSource: .sourceMenu
        case .channelUp, .channelDown: .channels
        case .guide: .guide
        case .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
            .numberPad
        }
    }
}

enum TVNetworkConnection: Equatable, Sendable {
    case unavailable
    case wireless
    case wired
}

/// A discovery result reduced to the fields a brand driver needs to start a session.
struct TVConnectionTarget: Equatable, Sendable {
    let brand: TVBrand
    let reportedDeviceID: String
    let address: PrivateIPv4Address
    let controlPort: UInt16?
    let suggestedDisplayName: String?
    /// Required authenticated identity for a remembered TV; nil only for explicit new setup.
    let expectedSavedDeviceID: String?
    /// Discovery metadata locates an endpoint, but never authorizes credential selection.
    let discoveryIdentifier: String?

    /// Creates a brand-scoped endpoint with optional user-facing discovery metadata.
    init(
        brand: TVBrand,
        reportedDeviceID: String,
        address: PrivateIPv4Address,
        controlPort: UInt16?,
        suggestedDisplayName: String? = nil,
        expectedSavedDeviceID: String? = nil,
        discoveryIdentifier: String? = nil
    ) {
        self.brand = brand
        self.reportedDeviceID = reportedDeviceID
        self.address = address
        self.controlPort = controlPort
        self.suggestedDisplayName = suggestedDisplayName
        self.expectedSavedDeviceID = expectedSavedDeviceID
        self.discoveryIdentifier = discoveryIdentifier
    }
    var discoveryDeviceKey: String {
        "\(brand.rawValue):\(discoveryIdentifier ?? reportedDeviceID)"
    }

    /// Rebinds an untrusted discovery endpoint to the TV the user actually selected.
    func expectingSavedIdentity(_ identity: String?) -> TVConnectionTarget {
        TVConnectionTarget(
            brand: brand,
            reportedDeviceID: reportedDeviceID,
            address: address,
            controlPort: controlPort,
            suggestedDisplayName: suggestedDisplayName,
            expectedSavedDeviceID: identity,
            discoveryIdentifier: discoveryIdentifier
        )
    }

    func validateConnectedIdentity(_ television: ConnectedTV) throws {
        guard television.brand == brand,
            expectedSavedDeviceID == nil || expectedSavedDeviceID == television.reportedDeviceID
        else {
            throw TVDriverError.savedDeviceIdentityMismatch
        }
    }
}

/// A validated hardware address that is never rendered or logged verbatim.
struct TVMACAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    let octets: [UInt8]

    init(_ value: String) throws {
        let compact = value.filter { $0 != ":" && $0 != "-" }
        guard compact.count == 12, compact.allSatisfy(\.isHexDigit) else {
            throw TVMACAddressError.invalid
        }

        var parsed: [UInt8] = []
        parsed.reserveCapacity(6)
        var index = compact.startIndex
        for _ in 0..<6 {
            let next = compact.index(index, offsetBy: 2)
            guard let octet = UInt8(compact[index..<next], radix: 16) else {
                throw TVMACAddressError.invalid
            }
            parsed.append(octet)
            index = next
        }

        guard
            parsed.contains(where: { $0 != 0 }),
            parsed.contains(where: { $0 != 0xFF }),
            parsed[0] & 1 == 0
        else {
            throw TVMACAddressError.invalid
        }
        octets = parsed
    }

    var persistedValue: String {
        octets.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    var description: String {
        "TVMACAddress(redacted)"
    }
}

enum TVMACAddressError: LocalizedError, Equatable, Sendable {
    case invalid

    var errorDescription: String? {
        "The TV did not provide a usable network address for power on."
    }
}

/// Brand-neutral information confirmed by a successful control connection.
struct ConnectedTV: Equatable, Sendable {
    let brand: TVBrand
    let reportedDeviceID: String
    let address: PrivateIPv4Address
    let controlPort: UInt16?
    let displayName: String?
    let modelName: String
    let firmwareVersion: String?
    let networkConnection: TVNetworkConnection
    let macAddress: TVMACAddress?
    let capabilities: Set<TVCapability>
    let discoveryIdentifier: String?
    let powerState: TVPowerState
    let capabilityEvidence: TVCapabilityEvidence

    init(
        brand: TVBrand = .samsung,
        reportedDeviceID: String,
        address: PrivateIPv4Address,
        controlPort: UInt16? = nil,
        displayName: String? = nil,
        modelName: String,
        firmwareVersion: String?,
        networkConnection: TVNetworkConnection = .unavailable,
        macAddress: TVMACAddress? = nil,
        capabilities: Set<TVCapability>? = nil,
        discoveryIdentifier: String? = nil,
        powerState: TVPowerState = .unknown,
        capabilityEvidence: TVCapabilityEvidence? = nil
    ) {
        self.brand = brand
        self.reportedDeviceID = reportedDeviceID
        self.address = address
        self.controlPort = controlPort
        self.displayName = Self.validatedDisplayName(displayName)
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.networkConnection = networkConnection
        self.macAddress = macAddress
        self.discoveryIdentifier = discoveryIdentifier
        var resolvedCapabilities = capabilities ?? TVCapability.implemented(for: brand)
        if capabilities == nil, brand == .samsung, networkConnection == .wireless, macAddress != nil {
            resolvedCapabilities.insert(.powerOn)
        }
        let evidence = capabilityEvidence ?? TVCapabilityEvidence(implemented: resolvedCapabilities)
        self.capabilityEvidence = evidence
        self.capabilities = evidence.internalAvailable
        self.powerState = powerState
    }

    var stableDeviceKey: String {
        "\(brand.rawValue):\(reportedDeviceID)"
    }

    var connectionTarget: TVConnectionTarget {
        TVConnectionTarget(
            brand: brand,
            reportedDeviceID: reportedDeviceID,
            address: address,
            controlPort: controlPort,
            suggestedDisplayName: displayName,
            expectedSavedDeviceID: reportedDeviceID,
            discoveryIdentifier: discoveryIdentifier
        )
    }

    /// Keeps a verified protocol name when available, otherwise using discovery metadata.
    func applyingDiscoveryMetadata(from target: TVConnectionTarget) -> ConnectedTV {
        ConnectedTV(
            brand: brand,
            reportedDeviceID: reportedDeviceID,
            address: address,
            controlPort: controlPort,
            displayName: displayName ?? target.suggestedDisplayName,
            modelName: modelName,
            firmwareVersion: firmwareVersion,
            networkConnection: networkConnection,
            macAddress: macAddress,
            capabilities: capabilities,
            discoveryIdentifier: target.discoveryIdentifier ?? discoveryIdentifier,
            powerState: powerState,
            capabilityEvidence: capabilityEvidence
        )
    }

    func applying(_ observation: TVSessionObservation) -> ConnectedTV {
        guard observation.stableDeviceKey == stableDeviceKey else { return self }
        return ConnectedTV(
            brand: brand, reportedDeviceID: reportedDeviceID, address: address,
            controlPort: controlPort, displayName: displayName, modelName: modelName,
            firmwareVersion: firmwareVersion, networkConnection: networkConnection,
            macAddress: macAddress, capabilities: capabilities, discoveryIdentifier: discoveryIdentifier,
            powerState: observation.powerState,
            capabilityEvidence: TVCapabilityEvidence(
                implemented: capabilityEvidence.implemented,
                protocolReported: observation.protocolReportedCapabilities
                    ?? capabilityEvidence.protocolReported,
                hardwareVerified: capabilityEvidence.hardwareVerified
            )
        )
    }

    var forgettingPowerObservation: ConnectedTV {
        applying(TVSessionObservation(stableDeviceKey: stableDeviceKey, powerState: .unknown))
    }

    var isEligibleForSamsungWake: Bool {
        brand == .samsung && networkConnection == .wireless
    }

    /// Removes non-displayable input before a network-provided name reaches the UI or storage.
    private static func validatedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = String(
            String.UnicodeScalarView(
                value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            )
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(80))
    }
}

typealias SamsungNetworkConnection = TVNetworkConnection
typealias SamsungMACAddress = TVMACAddress
typealias SamsungMACAddressError = TVMACAddressError
typealias PairedSamsungTV = ConnectedTV

/// The command boundary between product features and a television-specific protocol.
protocol TVDriver: Sendable {
    /// Whether cancelling an in-flight write can close this driver's active transport.
    func cancellationInvalidatesConnection() async -> Bool

    /// Verifies that the active control session is still usable without changing TV state.
    func checkConnection() async throws

    /// Reads protocol evidence without inferring screen state from socket liveness.
    func sessionObservation() async throws -> TVSessionObservation?
    func observations() async -> AsyncStream<TVSessionObservation>

    /// Sends one semantic remote action to the active television connection.
    func send(_ command: RemoteCommand) async throws

    /// Sends text to the text field currently focused on the television.
    func sendText(_ input: RemoteTextInput) async throws

    func convenience(_ request: TVConvenienceRequest) async throws -> TVConvenienceResponse

    /// Ends the active connection and releases its network resources.
    func disconnect() async
}

extension TVDriver {
    func cancellationInvalidatesConnection() async -> Bool { false }

    func convenience(_ request: TVConvenienceRequest) async throws -> TVConvenienceResponse {
        throw TVConvenienceError.unavailable
    }

    func sessionObservation() async throws -> TVSessionObservation? { nil }
    func observations() async -> AsyncStream<TVSessionObservation> {
        AsyncStream { $0.finish() }
    }

    func checkConnection() async throws {}

    func sendText(_ input: RemoteTextInput) async throws {
        throw TVDriverError.unsupportedTextInput
    }
}

/// Validated text that may cross the television protocol boundary.
struct RemoteTextInput: Equatable, Sendable, CustomStringConvertible {
    static let maximumCharacterCount = 256

    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty,
            value.count <= Self.maximumCharacterCount,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw RemoteTextInputError.invalidText
        }
        self.value = value
    }

    var description: String {
        "RemoteTextInput(redacted, characters: \(value.count))"
    }
}

enum RemoteTextInputError: LocalizedError, Equatable, Sendable {
    case invalidText

    var errorDescription: String? {
        "Enter between 1 and \(RemoteTextInput.maximumCharacterCount) characters without control characters."
    }
}

enum TVDriverError: LocalizedError, Equatable, Sendable {
    case unsupportedTextInput
    case unsupportedCommand
    case savedDeviceIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedCommand:
            "This TV has not made that control available."
        case .unsupportedTextInput:
            "This TV connection does not support remote text input."
        case .savedDeviceIdentityMismatch:
            "A different TV is using the remembered address. Find your TV again before connecting."
        }
    }
}
