import SwiftUI
import UIKit

struct RemoteControlButton: View {
    let command: RemoteCommand
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let isEnabled: Bool
    var role: ButtonRole?
    var size: CGFloat = 64
    var repeatsWhileHeld = false
    let action: @MainActor @Sendable (RemoteCommand) async -> Void

    var body: some View {
        Button(role: role) {
            sendOnce()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.34, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(RemoteControlButtonStyle(role: role))
        .buttonRepeatBehavior(repeatsWhileHeld && command.supportsRepeat ? .enabled : .disabled)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("remote-\(command.rawValue)")
    }

    private func sendOnce() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            await action(command)
        }
    }
}

private struct RemoteControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let role: ButtonRole?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(role == .destructive ? Color.red : Color.white)
            .background(Circle().fill(backgroundColor(isPressed: configuration.isPressed)))
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.34)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if role == .destructive {
            return Color.red.opacity(isPressed ? 0.28 : 0.14)
        }
        return isPressed ? HafaTheme.accent.opacity(0.34) : HafaTheme.surface
    }
}
