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
    var title: String?
    var isPrimary = false
    let action: @MainActor @Sendable (RemoteCommand) async -> Void

    var body: some View {
        Button(role: role) {
            sendOnce()
        } label: {
            Group {
                if let title {
                    Text(title)
                        .font(.headline.weight(.bold))
                } else {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                }
            }
            .frame(minWidth: max(size, 44), minHeight: max(size, 44))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(RemoteControlButtonStyle(role: role, isPrimary: isPrimary))
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

struct RemoteControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var role: ButtonRole? = nil
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                role == .destructive ? Color.red : isPrimary ? HafaTheme.onAccent : HafaTheme.primaryText
            )
            .background(
                RoundedRectangle(cornerRadius: 18).fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(HafaTheme.controlBorder, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if role == .destructive {
            return Color.red.opacity(isPressed ? 0.28 : 0.14)
        }
        if isPrimary { return HafaTheme.accent.opacity(isPressed ? 0.8 : 1) }
        return isPressed ? HafaTheme.accent.opacity(0.18) : HafaTheme.surface
    }
}
