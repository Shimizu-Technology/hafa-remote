import SwiftUI

/// Release-compatible exploration, always visibly separated from real TV control.
struct DemoRemoteView: View {
    @State private var model = DemoRemoteModel()
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Label("Offline Demo", systemImage: "play.rectangle")
                    .font(.headline)
                    .foregroundStyle(HafaTheme.accent)
                    .accessibilityIdentifier("offlineDemoLabel")
                Text(
                    "Explore Hafa Remote without a TV. These controls change only the preview on this phone."
                )
                .foregroundStyle(HafaTheme.secondaryText)
                .multilineTextAlignment(.center)
                demoScreen
                controlRows
                VStack(alignment: .leading, spacing: 12) {
                    Text("Try the keyboard").font(.headline)
                    TextField("Demo text", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("demoTextField")
                        .onChange(of: text) { _, value in
                            if value.count > RemoteTextInput.maximumCharacterCount {
                                text = String(value.prefix(RemoteTextInput.maximumCharacterCount))
                            }
                        }
                    Button("Try Text Entry") {
                        guard let input = try? RemoteTextInput(text) else { return }
                        model.sendText(input)
                        text = ""
                    }
                    .frame(minHeight: 44)
                    .buttonStyle(.bordered)
                    .disabled(!model.isPoweredOn || (try? RemoteTextInput(text)) == nil)
                    .accessibilityIdentifier("demoSendTextButton")
                }
                Text(
                    "Demo capabilities are simulated. Actual TV controls depend on the model, pairing, and verified protocol support."
                )
                .font(.footnote)
                .foregroundStyle(HafaTheme.secondaryText)
            }
            .padding(20)
        }
        .background(HafaTheme.canvas)
        .navigationTitle("Try the Remote")
        .navigationBarTitleDisplayMode(.inline)
        .tint(HafaTheme.accent)
        .onAppear {
            model = DemoRemoteModel()
            text = ""
        }
        .onDisappear { text = "" }
    }

    private var demoScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.isPoweredOn ? "Demo screen on" : "Demo screen off", systemImage: "tv")
                .font(.headline)
                .accessibilityIdentifier("demoPowerState")
            if model.isPoweredOn {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(model.tiles.enumerated()), id: \.offset) { index, title in
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(6)
                            .background(
                                model.focusedTile == index
                                    ? HafaTheme.accent.opacity(0.18) : HafaTheme.canvas,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .overlay {
                                if model.focusedTile == index {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(HafaTheme.accent, lineWidth: 2)
                                }
                            }
                            .accessibilityLabel(model.focusedTile == index ? "\(title), focused" : title)
                    }
                }
                Label(
                    "Volume \(model.volume)\(model.isMuted ? ", muted" : "")",
                    systemImage: model.isMuted ? "speaker.slash" : "speaker.wave.2"
                )
                .accessibilityIdentifier("demoVolumeState")
            }
            Text(model.activity)
                .font(.subheadline)
                .foregroundStyle(HafaTheme.secondaryText)
                .accessibilityIdentifier("demoActivity")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(HafaTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var controlRows: some View {
        VStack(spacing: 12) {
            commandButton(
                model.isPoweredOn ? .powerOff : .powerOn,
                title: model.isPoweredOn ? "Turn Demo Off" : "Turn Demo On", symbol: "power", enabled: true)
            commandButton(.up, title: "Up", symbol: "chevron.up")
            adaptiveRow {
                commandButton(.left, title: "Left", symbol: "chevron.left")
                commandButton(.select, title: "Select", symbol: "checkmark.circle")
                commandButton(.right, title: "Right", symbol: "chevron.right")
            }
            commandButton(.down, title: "Down", symbol: "chevron.down")
            adaptiveRow {
                commandButton(.back, title: "Back", symbol: "arrow.uturn.backward")
                commandButton(.home, title: "Home", symbol: "house")
            }
            adaptiveRow {
                commandButton(.volumeDown, title: "Quieter", symbol: "speaker.minus")
                commandButton(.mute, title: "Mute", symbol: "speaker.slash")
                commandButton(.volumeUp, title: "Louder", symbol: "speaker.plus")
            }
            adaptiveRow {
                commandButton(.rewind, title: "Rewind", symbol: "backward")
                commandButton(
                    model.isPlaying ? .pause : .play, title: model.isPlaying ? "Pause" : "Play",
                    symbol: model.isPlaying ? "pause" : "play")
                commandButton(.fastForward, title: "Forward", symbol: "forward")
            }
        }
    }

    private func adaptiveRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8, content: content)
            VStack(spacing: 8, content: content)
        }
    }

    private func commandButton(_ command: RemoteCommand, title: String, symbol: String, enabled: Bool? = nil)
        -> some View
    {
        Button {
            model.send(command)
        } label: {
            Label(title, systemImage: symbol)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!(enabled ?? model.isPoweredOn))
        .accessibilityLabel("Demo \(title.lowercased())")
        .accessibilityIdentifier("demo-\(command.rawValue)")
    }
}
