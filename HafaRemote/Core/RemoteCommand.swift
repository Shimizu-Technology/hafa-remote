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
    case inputSource
    case channelUp
    case channelDown
    case guide
    case digit0
    case digit1
    case digit2
    case digit3
    case digit4
    case digit5
    case digit6
    case digit7
    case digit8
    case digit9

    var digit: Int? {
        guard rawValue.hasPrefix("digit") else { return nil }
        return Int(rawValue.dropFirst(5))
    }

    var supportsRepeat: Bool {
        switch self {
        case .up, .down, .left, .right, .volumeUp, .volumeDown, .channelUp, .channelDown:
            true
        case .powerOn, .powerOff, .select, .home, .back, .play, .pause, .rewind, .fastForward,
            .mute, .inputSource, .guide, .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6,
            .digit7, .digit8, .digit9:
            false
        }
    }
}
