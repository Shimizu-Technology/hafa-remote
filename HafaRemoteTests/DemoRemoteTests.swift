import Testing

@testable import HafaRemote

@MainActor
struct DemoRemoteTests {
    @Test("A demo controls only its own ephemeral state")
    func isolatedDemoState() {
        let first = DemoRemoteModel()
        let second = DemoRemoteModel()
        first.send(.right)
        first.send(.volumeUp)
        first.send(.mute)
        first.send(.play)
        #expect(first.focusedTile == 1)
        #expect(first.volume == 21)
        #expect(first.isMuted)
        #expect(first.isPlaying)
        #expect(second.focusedTile == 0)
        #expect(second.volume == 20)
        #expect(!second.isMuted)
        #expect(!second.isPlaying)
    }

    @Test("Sleeping demo ignores control and text until explicitly powered on")
    func simulatedPower() throws {
        let model = DemoRemoteModel()
        model.send(.powerOff)
        model.send(.volumeUp)
        model.send(.right)
        model.sendText(try RemoteTextInput("synthetic demo text"))
        #expect(!model.isPoweredOn)
        #expect(model.volume == 20)
        #expect(model.focusedTile == 0)
        #expect(model.textCharacterCount == 0)
        model.send(.powerOn)
        model.send(.volumeUp)
        #expect(model.isPoweredOn)
        #expect(model.volume == 21)
    }

    @Test("Navigation and volume remain in range after sustained use")
    func boundedControls() {
        let model = DemoRemoteModel()
        for _ in 0..<200 {
            model.send(.right)
            model.send(.down)
            model.send(.volumeUp)
        }
        #expect(model.focusedTile == model.tiles.count - 1)
        #expect(model.volume == 100)
        model.send(.select)
        #expect(model.activity.contains("Settings"))
        for _ in 0..<200 {
            model.send(.left)
            model.send(.up)
            model.send(.volumeDown)
        }
        #expect(model.focusedTile == 0)
        #expect(model.volume == 0)
    }

    @Test("Entered demo text is reduced to a count and never retained")
    func textIsNotRetained() throws {
        let model = DemoRemoteModel()
        let syntheticText = "Håfa synthetic 👋"
        model.sendText(try RemoteTextInput(syntheticText))
        #expect(model.textCharacterCount == syntheticText.count)
        #expect(!model.activity.contains(syntheticText))
        #expect(model.activity.contains("No text was sent to a TV"))
    }
}
