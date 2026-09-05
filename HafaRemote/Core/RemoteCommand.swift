import Foundation

/// Brand-neutral actions the interface can ask a television to perform.
enum RemoteCommand: String, CaseIterable, Codable, Equatable, Sendable {
    case powerOn
    case powerOff
    case up
    case down
    case left
    case right
    case select
    case home
    case back
    case play
    case pause
    case rewind
    case fastForward
    case volumeUp
    case volumeDown
    case mute

    var supportsRepeat: Bool {
        switch self {
        case .up, .down, .left, .right, .volumeUp, .volumeDown:
            true
        case .powerOn, .powerOff, .select, .home, .back, .play, .pause, .rewind, .fastForward,
            .mute:
            false
        }
    }
}
