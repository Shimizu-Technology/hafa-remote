import Foundation
import Observation

/// Only reviewed semantic events can enter the diagnostic buffer. No payload is accepted.
enum DiagnosticEventKind: String, CaseIterable, Sendable {
    case discoveryStarted = "Discovery started"
    case discoveryFinished = "Discovery finished"
    case pairingStarted = "Pairing started"
    case pairingApproved = "Pairing approved"
    case pairingDenied = "Pairing denied"
    case connectionStarted = "Connection started"
    case connectionReady = "Connection ready"
    case connectionUnavailable = "Connection unavailable"
    case connectionTimedOut = "Connection timed out"
    case reconnectStarted = "Reconnect started"
    case pairingExpired = "Saved pairing rejected"
    case certificateChanged = "Certificate changed; verification needed"
    case commandSent = "Command sent; execution not confirmed"
    case commandDeliveryFailed = "Command delivery failed"
    case textSent = "Text sent; entry not confirmed"
    case textDeliveryFailed = "Text delivery failed"
    case wakeRequested = "Wake requested"
    case wakeUnavailable = "Wake unavailable"
    case appBackgrounded = "App backgrounded"
    case appForegrounded = "App foregrounded"
}

enum DiagnosticDuration: String, Sendable {
    case underOneSecond = "less than 1 second"
    case oneToThreeSeconds = "1–3 seconds"
    case threeToTenSeconds = "3–10 seconds"
    case tenSecondsOrMore = "10 seconds or more"
    case unknown = "not measured"

    init(seconds: TimeInterval?) {
        guard let seconds, seconds.isFinite, seconds >= 0 else {
            self = .unknown
            return
        }
        switch seconds {
        case ..<1: self = .underOneSecond
        case ..<3: self = .oneToThreeSeconds
        case ..<10: self = .threeToTenSeconds
        default: self = .tenSecondsOrMore
        }
    }
}

struct DiagnosticEvent: Equatable, Sendable {
    let kind: DiagnosticEventKind
    let duration: DiagnosticDuration
}

/// A strict defense-in-depth filter for version/model fields, never for names or identities.
struct DiagnosticMetadata: Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    let iOSVersion: String
    let tvModel: String
    let tvFirmware: String

    init(
        appVersion: String,
        appBuild: String,
        iOSVersion: String,
        tvModel: String? = nil,
        tvFirmware: String? = nil
    ) {
        self.appVersion = Self.safeField(appVersion)
        self.appBuild = Self.safeField(appBuild)
        self.iOSVersion = Self.safeField(iOSVersion)
        self.tvModel = Self.safeField(tvModel)
        self.tvFirmware = Self.safeField(tvFirmware)
    }

    static func current(tvModel: String? = nil, tvFirmware: String? = nil) -> Self {
        Self(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "Unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
            iOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            tvModel: tvModel,
            tvFirmware: tvFirmware
        )
    }

    static func current(verifiedTV television: ConnectedTV) -> Self {
        // Sony can fall back to its certificate display name when no model was reported.
        // Omitting a model that equals that name is conservative for every brand.
        let normalizedModel = Self.normalizedModelField(television.modelName)
        let normalizedName = television.displayName.map(Self.normalizedModelField)
        let model = normalizedModel == normalizedName ? nil : normalizedModel
        return current(tvModel: model, tvFirmware: television.firmwareVersion)
    }

    private static func normalizedModelField(_ value: String) -> String {
        String(
            String.UnicodeScalarView(
                value.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0)
                })
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeField(_ value: String?) -> String {
        guard let value else { return "Not included" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()"))
        guard !trimmed.isEmpty, trimmed.utf8.count <= 80,
            trimmed.unicodeScalars.allSatisfy(allowed.contains)
        else { return "Not included" }
        // Reject network addresses and common identifier shapes even in otherwise valid fields.
        let excludedPatterns = [
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
            #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
            #"(?i)\b[0-9a-f]{32,}\b"#,
            #"(?i)\b(?:token|password|secret|serial|ssid|credential|certificate)\b"#,
            #"(?i)\b(?:[0-9a-f]{2}[-.]){5}[0-9a-f]{2}\b"#,
        ]
        guard !excludedPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil })
        else {
            return "Not included"
        }
        return trimmed
    }
}

struct DiagnosticReport: Equatable, Sendable {
    let metadata: DiagnosticMetadata
    let events: [DiagnosticEvent]

    var text: String {
        var lines = [
            "Hafa Remote — Support Report",
            "App: \(metadata.appVersion) (\(metadata.appBuild))",
            "iOS: \(metadata.iOSVersion)",
            "TV model: \(metadata.tvModel)",
            "TV firmware: \(metadata.tvFirmware)",
            "",
            "No addresses, device identities, TV names, Wi-Fi names, credentials, certificates, or entered text are collected.",
            "Events are in order, with coarse operation durations. Sending does not confirm TV execution.",
            "",
            "Recent events:",
        ]
        if events.isEmpty {
            lines.append("No events recorded. Turn on diagnostics, reproduce the issue, then preview again.")
        } else {
            for (index, event) in events.enumerated() {
                lines.append("\(index + 1). \(event.kind.rawValue) (\(event.duration.rawValue))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// An opaque, process-local lease. It never enters the report or persistence.
struct DiagnosticCollectionToken: Equatable, Sendable {
    fileprivate let epoch: UUID
}

/// An opt-in, memory-only ring buffer. Disabling collection removes its contents.
@MainActor
@Observable
final class DiagnosticRecorder {
    static let maximumEventCount = 100
    private(set) var isEnabled = false
    private(set) var events: [DiagnosticEvent] = []
    private var collectionEpoch = UUID()
    private var epochStartedAt: ContinuousClock.Instant = .now

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        clear()
    }

    func record(_ kind: DiagnosticEventKind, durationSeconds: TimeInterval? = nil) {
        record(kind, durationSeconds: durationSeconds, collection: captureCollection())
    }

    /// Completion events must carry the lease acquired when their operation began.
    func record(
        _ kind: DiagnosticEventKind, durationSeconds: TimeInterval? = nil,
        collection: DiagnosticCollectionToken?
    ) {
        guard isEnabled, let collection, collection.epoch == collectionEpoch else { return }
        if events.count == Self.maximumEventCount { events.removeFirst() }
        events.append(DiagnosticEvent(kind: kind, duration: DiagnosticDuration(seconds: durationSeconds)))
    }

    /// The first result or terminal state completes the scan using its original consent lease.
    /// Later result updates cannot duplicate completion or acquire consent after Clear.
    func finishDiscovery(collection: inout DiagnosticCollectionToken?) {
        let startedCollection = collection
        collection = nil
        record(.discoveryFinished, collection: startedCollection)
    }

    func captureCollection(producedAt: ContinuousClock.Instant? = nil) -> DiagnosticCollectionToken? {
        guard isEnabled, producedAt.map({ $0 >= epochStartedAt }) ?? true else { return nil }
        return DiagnosticCollectionToken(epoch: collectionEpoch)
    }

    func clear() {
        collectionEpoch = UUID()
        epochStartedAt = .now
        events.removeAll(keepingCapacity: false)
    }

    func report(metadata: DiagnosticMetadata) -> DiagnosticReport {
        DiagnosticReport(metadata: metadata, events: events)
    }
}
