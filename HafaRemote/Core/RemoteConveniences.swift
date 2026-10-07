import Foundation
import Observation

enum TVConvenienceError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidResponse
    case busy
    case timedOut
    case textFieldNotFocused
    case wrongTV

    var errorDescription: String? {
        switch self {
        case .unavailable: "This TV connection does not provide that feature."
        case .invalidResponse: "The TV returned an unsupported response for this feature."
        case .busy: "A request is already in progress. Try again shortly."
        case .timedOut:
            "The TV did not provide this feature in time. Other remote controls are still available."
        case .textFieldNotFocused:
            "Focus a text field on the TV, then try again. If its keyboard cannot open, turn remote keyboard support off."
        case .wrongTV: "This shortcut belongs to another TV. Choose a shortcut for the selected TV."
        }
    }
}

enum SonyAppLink: String, CaseIterable, Codable, Sendable {
    case youtube, netflix, primeVideo, disneyPlus
    var value: String {
        switch self {
        case .youtube: "https://www.youtube.com"
        case .netflix: "netflix://"
        case .primeVideo: "https://app.primevideo.com"
        case .disneyPlus: "https://www.disneyplus.com"
        }
    }
    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .netflix: "Netflix"
        case .primeVideo: "Prime Video"
        case .disneyPlus: "Disney+"
        }
    }
}

enum TVAppTarget: Codable, Equatable, Hashable, Sendable {
    case samsung(appID: String, deepLink: Bool)
    case sony(SonyAppLink)
    case vizio(appID: String, namespace: Int)

    var brand: TVBrand {
        switch self {
        case .samsung: .samsung
        case .sony: .sony
        case .vizio: .vizio
        }
    }

    var isValid: Bool {
        switch self {
        case .samsung(let id, _): RemoteConvenienceValidation.identifier(id)
        case .sony: true
        case .vizio(let id, let namespace):
            RemoteConvenienceValidation.identifier(id) && (1...20).contains(namespace)
        }
    }
}

struct TVAppShortcut: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let target: TVAppTarget
    var id: TVAppTarget { target }
    init(name: String, target: TVAppTarget) throws {
        guard RemoteConvenienceValidation.label(name), target.isValid else {
            throw TVConvenienceError.invalidResponse
        }
        self.name = name
        self.target = target
    }

    static var sonyConfiguredLinks: [Self] {
        SonyAppLink.allCases.compactMap { try? Self(name: $0.name, target: .sony($0)) }
    }
}

struct TVInputSource: Equatable, Identifiable, Sendable {
    let value: String
    let name: String
    var id: String { value }
    init(value: String, name: String) throws {
        guard RemoteConvenienceValidation.label(value), RemoteConvenienceValidation.label(name) else {
            throw TVConvenienceError.invalidResponse
        }
        self.value = value
        self.name = name
    }
}

enum TVConvenienceRequest: Equatable, Sendable {
    case apps
    case inputs
    case selectInput(TVInputSource)
    case launch(TVAppShortcut)
    case currentApp
    case setKeyboardEnabled(Bool)

    var changesTVState: Bool {
        switch self {
        case .launch, .selectInput, .setKeyboardEnabled: true
        case .apps, .inputs, .currentApp: false
        }
    }
}

enum TVConvenienceResponse: Equatable, Sendable {
    case apps([TVAppShortcut])
    case inputs([TVInputSource])
    case currentApp(TVAppShortcut?)
    /// The request was sent or accepted; foreground/display execution is not confirmed.
    case sent
}

enum RemoteConvenienceValidation {
    static func label(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 128
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    static func identifier(_ value: String) -> Bool {
        label(value)
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
                ).contains($0)
            }
    }
}

/// Local preferences contain launch descriptors, never pairing credentials or network addresses.
@MainActor
@Observable
final class TVConveniencePreferences {
    static let shared = TVConveniencePreferences()
    private let defaults: UserDefaults
    private let storageKey = "hafaRemote.conveniencePreferences.v1"
    private var entries: [String: Entry]
    private struct Entry: Codable {
        var favorites: [TVAppShortcut] = []
        var keyboardEnabled = true
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey), data.count <= 262_144,
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data), decoded.count <= 100
        {
            entries = decoded
        } else {
            entries = [:]
        }
    }
    func favorites(for stableDeviceKey: String) -> [TVAppShortcut] {
        guard let brand = brand(for: stableDeviceKey) else { return [] }
        return Array(
            (entries[stableDeviceKey]?.favorites ?? []).filter {
                $0.target.brand == brand && $0.target.isValid && RemoteConvenienceValidation.label($0.name)
            }.prefix(12))
    }
    func toggleFavorite(_ shortcut: TVAppShortcut, for stableDeviceKey: String) throws {
        guard brand(for: stableDeviceKey) == shortcut.target.brand, shortcut.target.isValid,
            RemoteConvenienceValidation.label(shortcut.name)
        else { throw TVConvenienceError.wrongTV }
        var entry = entries[stableDeviceKey] ?? Entry()
        entry.favorites = favorites(for: stableDeviceKey)
        if let index = entry.favorites.firstIndex(where: { $0.target == shortcut.target }) {
            entry.favorites.remove(at: index)
        } else {
            guard entry.favorites.count < 12 else { throw TVConvenienceError.unavailable }
            entry.favorites.append(shortcut)
        }
        try save(entry, for: stableDeviceKey)
    }
    func keyboardEnabled(for stableDeviceKey: String) -> Bool {
        entries[stableDeviceKey]?.keyboardEnabled ?? true
    }
    func setKeyboardEnabled(_ enabled: Bool, for stableDeviceKey: String) throws {
        guard brand(for: stableDeviceKey) == .sony else { return }
        var entry = entries[stableDeviceKey] ?? Entry()
        entry.keyboardEnabled = enabled
        try save(entry, for: stableDeviceKey)
    }
    func forget(stableDeviceKey: String) {
        var updated = entries
        updated[stableDeviceKey] = nil
        guard persist(updated) else { return }
        entries = updated
    }
    private func brand(for key: String) -> TVBrand? {
        guard key.utf8.count <= 1024, let separator = key.firstIndex(of: ":"),
            key.index(after: separator) < key.endIndex
        else { return nil }
        return TVBrand(rawValue: String(key[..<separator]))
    }
    private func save(_ entry: Entry, for key: String) throws {
        var updated = entries
        updated[key] = entry
        guard persist(updated) else {
            throw TVConvenienceError.unavailable
        }
        entries = updated
    }
    private func persist(_ updated: [String: Entry]) -> Bool {
        guard updated.count <= 100, let data = try? JSONEncoder().encode(updated), data.count <= 262_144
        else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }
}

actor TVConvenienceResultBox {
    private var response: TVConvenienceResponse?
    func store(_ response: TVConvenienceResponse) { self.response = response }
    func value() throws -> TVConvenienceResponse {
        guard let response else { throw CancellationError() }
        return response
    }
}

/// One completed gesture produces at most one ordinary D-pad action.
enum RemoteSwipeMapping {
    static func command(horizontal: Double, vertical: Double) -> RemoteCommand? {
        guard horizontal.isFinite, vertical.isFinite else { return nil }
        let x = abs(horizontal)
        let y = abs(vertical)
        guard max(x, y) >= 24 else { return nil }
        guard max(x, y) >= min(x, y) * 1.25 else { return nil }
        return x > y ? (horizontal > 0 ? .right : .left) : (vertical > 0 ? .down : .up)
    }
}

/// Manual endpoints locate a pairing candidate; only authenticated protocol data is identity.
enum ManualTVTargetFactory {
    static func target(address: PrivateIPv4Address, brand: TVBrand, savedTarget: TVConnectionTarget? = nil)
        -> TVConnectionTarget
    {
        let port: UInt16
        switch brand {
        case .samsung: port = 8002
        case .sony: port = 6466
        case .vizio: port = 7345
        }
        let remembered = savedTarget?.brand == brand ? savedTarget : nil
        let rememberedPort = remembered?.controlPort
        let usesKnownLegacyPort = brand == .vizio && rememberedPort == 9000
        return TVConnectionTarget(
            brand: brand,
            reportedDeviceID: remembered?.reportedDeviceID ?? "manual-pairing-candidate",
            address: address,
            controlPort: usesKnownLegacyPort ? 9000 : port,
            expectedSavedDeviceID: remembered?.expectedSavedDeviceID,
            discoveryIdentifier: remembered?.discoveryIdentifier
        )
    }
}
