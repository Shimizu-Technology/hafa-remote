import Foundation

/// Brand-neutral actions the interface can ask a television to perform.
enum RemoteCommand: String, Codable, Equatable, Sendable {
    case select
}
