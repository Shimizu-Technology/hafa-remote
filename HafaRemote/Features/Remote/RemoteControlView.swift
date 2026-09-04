import SwiftUI
import UIKit

struct RemoteControlView: View {
    let tvName: String
    let modelName: String
    let statusLabel: String
    let isConnected: Bool
    let action: @MainActor @Sendable (RemoteCommand) async -> Void

    @State private var isConfirmingPowerOff = false

    var body: some View {
        ZStack {
            HafaTheme.canvas
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    remoteHeader
                    navigationControls
                    utilityControls
                    volumeControls
                    playbackControls
                    keyboardControl
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Remote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Turn off \(tvName)?",
            isPresented: $isConfirmingPowerOff,
            titleVisibility: .visible
        ) {
            Button("Turn Off", role: .destructive) {
                send(.powerOff)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Power on is available only after wake support is verified for this TV.")
        }
    }

    private var remoteHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tvName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(modelName)
                        .font(.subheadline)
                        .foregroundStyle(HafaTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    isConfirmingPowerOff = true
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!isConnected)
                .accessibilityLabel("Power off TV")
                .accessibilityHint("Asks for confirmation before turning off the TV.")
                .accessibilityIdentifier("remote-powerOff")
            }

            Label(
                statusLabel,
                systemImage: isConnected
                    ? "checkmark.circle.fill" : "arrow.trianglehead.2.clockwise.rotate.90"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(isConnected ? HafaTheme.accent : .orange)
            .labelStyle(.titleAndIcon)
            .accessibilityIdentifier("remoteConnectionStatus")
        }
        .padding(16)
        .background(HafaTheme.surface.opacity(0.76), in: RoundedRectangle(cornerRadius: 22))
    }

    private var navigationControls: some View {
        VStack(spacing: 8) {
            RemoteControlButton(
                command: .up,
                systemImage: "chevron.up",
                accessibilityLabel: "Navigate up",
                accessibilityHint: "Moves focus up. Hold to repeat.",
                isEnabled: isConnected,
                repeatsWhileHeld: true,
                action: action
            )

            HStack(spacing: 8) {
                RemoteControlButton(
                    command: .left,
                    systemImage: "chevron.left",
                    accessibilityLabel: "Navigate left",
                    accessibilityHint: "Moves focus left. Hold to repeat.",
                    isEnabled: isConnected,
                    repeatsWhileHeld: true,
                    action: action
                )

                RemoteControlButton(
                    command: .select,
                    systemImage: "circle.inset.filled",
                    accessibilityLabel: "Select",
                    accessibilityHint: "Activates the focused item.",
                    isEnabled: isConnected,
                    size: 76,
                    action: action
                )

                RemoteControlButton(
                    command: .right,
                    systemImage: "chevron.right",
                    accessibilityLabel: "Navigate right",
                    accessibilityHint: "Moves focus right. Hold to repeat.",
                    isEnabled: isConnected,
                    repeatsWhileHeld: true,
                    action: action
                )
            }

            RemoteControlButton(
                command: .down,
                systemImage: "chevron.down",
                accessibilityLabel: "Navigate down",
                accessibilityHint: "Moves focus down. Hold to repeat.",
                isEnabled: isConnected,
                repeatsWhileHeld: true,
                action: action
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation controls")
    }

    private var utilityControls: some View {
        HStack(spacing: 18) {
            labeledControl(
                command: .back,
                systemImage: "arrow.uturn.backward",
                label: "Back",
                hint: "Returns to the previous TV screen."
            )
            labeledControl(
                command: .home,
                systemImage: "house.fill",
                label: "Home",
                hint: "Opens the TV home screen."
            )
        }
    }

    private var volumeControls: some View {
        controlGroup(title: "Volume") {
            HStack(spacing: 18) {
                labeledControl(
                    command: .volumeDown,
                    systemImage: "speaker.minus.fill",
                    label: "Down",
                    hint: "Lowers volume. Hold to repeat.",
                    repeats: true
                )
                labeledControl(
                    command: .mute,
                    systemImage: "speaker.slash.fill",
                    label: "Mute",
                    hint: "Toggles mute."
                )
                labeledControl(
                    command: .volumeUp,
                    systemImage: "speaker.plus.fill",
                    label: "Up",
                    hint: "Raises volume. Hold to repeat.",
                    repeats: true
                )
            }
        }
    }

    private var playbackControls: some View {
        controlGroup(title: "Playback") {
            HStack(spacing: 12) {
                compactControl(.rewind, image: "backward.fill", label: "Rewind")
                compactControl(.play, image: "play.fill", label: "Play")
                compactControl(.pause, image: "pause.fill", label: "Pause")
                compactControl(.fastForward, image: "forward.fill", label: "Fast forward")
            }
        }
    }

    private var keyboardControl: some View {
        Button {
        } label: {
            Label("Keyboard", systemImage: "keyboard")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
        }
        .buttonStyle(.bordered)
        .tint(HafaTheme.secondaryText)
        .disabled(true)
        .accessibilityHint("Text entry becomes available after this TV's keyboard support is verified.")
        .accessibilityIdentifier("remote-keyboard")
    }

    private func controlGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(HafaTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(HafaTheme.surface.opacity(0.52), in: RoundedRectangle(cornerRadius: 22))
    }

    private func labeledControl(
        command: RemoteCommand,
        systemImage: String,
        label: String,
        hint: String,
        repeats: Bool = false
    ) -> some View {
        VStack(spacing: 7) {
            RemoteControlButton(
                command: command,
                systemImage: systemImage,
                accessibilityLabel: label,
                accessibilityHint: hint,
                isEnabled: isConnected,
                repeatsWhileHeld: repeats,
                action: action
            )
            Text(label)
                .font(.caption)
                .foregroundStyle(HafaTheme.secondaryText)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private func compactControl(
        _ command: RemoteCommand,
        image: String,
        label: String
    ) -> some View {
        RemoteControlButton(
            command: command,
            systemImage: image,
            accessibilityLabel: label,
            accessibilityHint: "Sends \(label.lowercased()) to the active TV app.",
            isEnabled: isConnected,
            size: 56,
            action: action
        )
    }

    private func send(_ command: RemoteCommand) {
        guard isConnected else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            await action(command)
        }
    }
}

#if DEBUG
    struct RemoteControlTestHarness: View {
        @State private var lastCommand = "none"

        var body: some View {
            NavigationStack {
                RemoteControlView(
                    tvName: "Living Room TV",
                    modelName: "Q70AA",
                    statusLabel: "Connected",
                    isConnected: true
                ) { command in
                    lastCommand = command.rawValue
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(lastCommand)
                    .font(.caption2)
                    .accessibilityIdentifier("lastRemoteCommand")
                    .opacity(0.01)
            }
        }
    }
#endif
