import Foundation
import Observation

/// An isolated simulator of ordinary commands, never a TVDriver or saved device.
@MainActor
@Observable
final class DemoRemoteModel {
    let tvName = "Demo TV"
    let modelName = "Offline preview"
    let capabilities: Set<TVCapability> = [
        .navigation, .volume, .mute, .playback, .textInput, .powerOn, .powerOff,
    ]
    let tiles = ["Watch", "Listen", "Explore", "Relax", "Favorites", "Settings"]
    private(set) var isPoweredOn = true
    private(set) var volume = 20
    private(set) var isMuted = false
    private(set) var isPlaying = false
    private(set) var focusedTile = 0
    private(set) var activity = "Try the remote below. No TV is connected."
    private(set) var textCharacterCount = 0

    func send(_ command: RemoteCommand) {
        if command == .powerOn {
            isPoweredOn = true
            activity = "Demo screen turned on."
            return
        }
        guard isPoweredOn else { return }
        switch command {
        case .powerOff:
            isPoweredOn = false
            isPlaying = false
            activity = "Demo screen turned off."
        case .up: focusedTile = max(0, focusedTile - 2)
        case .down: focusedTile = min(tiles.count - 1, focusedTile + 2)
        case .left: focusedTile = max(0, focusedTile - 1)
        case .right: focusedTile = min(tiles.count - 1, focusedTile + 1)
        case .select: activity = "Opened \(tiles[focusedTile]) in the demo."
        case .home:
            focusedTile = 0
            activity = "Demo home screen."
        case .back: activity = "Returned to the demo home screen."
        case .volumeUp: volume = min(100, volume + 1)
        case .volumeDown: volume = max(0, volume - 1)
        case .mute: isMuted.toggle()
        case .play:
            isPlaying = true
            activity = "Demo playback started."
        case .pause:
            isPlaying = false
            activity = "Demo playback paused."
        case .rewind: activity = "Demo playback rewound."
        case .fastForward: activity = "Demo playback advanced."
        case .powerOn: break
        }
    }

    /// Only a character count survives the call; entered demo text is not retained.
    func sendText(_ input: RemoteTextInput) {
        guard isPoweredOn else { return }
        textCharacterCount = input.value.count
        activity = "Demo received \(textCharacterCount) characters. No text was sent to a TV."
    }
}
