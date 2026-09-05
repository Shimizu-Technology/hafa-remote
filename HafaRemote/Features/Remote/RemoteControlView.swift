import SwiftUI
import UIKit

struct RemoteControlView: View {
    @Environment(\.openURL) private var openURL

    let tvName: String
    let modelName: String
    let statusLabel: String
    let isConnected: Bool
    let canWakeTV: Bool
    let wakeWasVerified: Bool
    let action: @MainActor @Sendable (RemoteCommand) async -> Void
    let textAction: @MainActor @Sendable (RemoteTextInput) async throws -> Void
    let wakeAction: @MainActor @Sendable () async throws -> Void
    let retry: @MainActor @Sendable () async -> Void
    let showTVSetup: @MainActor @Sendable () -> Void

    @State private var isConfirmingPowerOff = false
    @State private var isShowingKeyboard = false
    @State private var isWakingTV = false
    @State private var wakeTask: Task<Void, Never>?
    @State private var wakeFailureMessage: String?

    var body: some View {
        ZStack {
            HafaTheme.canvas
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    remoteHeader
                    if !isConnected {
                        recoveryControls
                    }
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
        .onChange(of: isConnected) { wasConnected, isConnected in
            if isConnected {
                isWakingTV = false
                wakeFailureMessage = nil
            }
            guard wasConnected, !isConnected else { return }
            UIAccessibility.post(
                notification: .announcement,
                argument: "The TV connection is offline. Recovery controls are now available."
            )
        }
        .onChange(of: isWakingTV) { _, isWakingTV in
            guard isWakingTV else { return }
            UIAccessibility.post(notification: .announcement, argument: recoveryMessage)
        }
        .alert(
            "Turn off \(tvName)?",
            isPresented: $isConfirmingPowerOff
        ) {
            Button("Turn Off", role: .destructive) {
                send(.powerOff)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if canWakeTV {
                Text("You can try turning it back on here when Power On With Mobile is enabled on the TV.")
            } else {
                Text("Reconnect once while the TV is on before Hafa Remote can prepare power on.")
            }
        }
        .alert(
            "Couldn’t Wake TV",
            isPresented: Binding(
                get: { wakeFailureMessage != nil },
                set: { if !$0 { wakeFailureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(wakeFailureMessage ?? "")
        }
        .sheet(isPresented: $isShowingKeyboard) {
            SamsungTextInputSheet(
                tvName: tvName,
                isConnected: isConnected,
                send: textAction
            )
        }
        .onDisappear {
            wakeTask?.cancel()
            wakeTask = nil
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
                    if isConnected {
                        isConfirmingPowerOff = true
                    } else {
                        wakeTV()
                    }
                } label: {
                    Group {
                        if isWakingTV {
                            ProgressView()
                                .tint(HafaTheme.accent)
                        } else {
                            Image(systemName: "power")
                                .font(.system(size: 18, weight: .semibold))
                        }
                    }
                    .frame(width: 46, height: 46)
                }
                .buttonStyle(.bordered)
                .tint(isConnected ? .red : HafaTheme.accent)
                .disabled(!isConnected && (!canWakeTV || isWakingTV))
                .accessibilityLabel(isConnected ? "Power off TV" : "Turn on TV")
                .accessibilityHint(powerAccessibilityHint)
                .accessibilityIdentifier(isConnected ? "remote-powerOff" : "remote-powerOn")
            }

            Label(
                isWakingTV ? "Waking TV…" : statusLabel,
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

    private var recoveryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recoveryMessage)
                .font(.subheadline)
                .foregroundStyle(HafaTheme.secondaryText)

            if canWakeTV {
                Label(
                    wakeWasVerified
                        ? "Power on worked previously for this TV and network."
                        : "Requires Power On With Mobile in the TV's Network settings.",
                    systemImage: wakeWasVerified ? "checkmark.circle" : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(HafaTheme.secondaryText)
                .accessibilityIdentifier("wakeCapabilityMessage")
            }

            Button {
                Task { @MainActor in
                    await retry()
                }
            } label: {
                Label("Retry Connection", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(HafaTheme.accent)
            .foregroundStyle(HafaTheme.canvas)
            .disabled(isWakingTV)
            .accessibilityIdentifier("retryConnectionButton")

            HStack {
                Button("TV Setup", systemImage: "tv.badge.wifi") {
                    showTVSetup()
                }
                .frame(minHeight: 46)
                .accessibilityIdentifier("remoteTVSetupButton")

                Spacer()

                Button("iOS Settings", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .frame(minHeight: 46)
                .accessibilityIdentifier("openIOSSettingsButton")
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(HafaTheme.surface.opacity(0.76), in: RoundedRectangle(cornerRadius: 22))
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
                    accessibilityLabel: "Volume down",
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
                    accessibilityLabel: "Volume up",
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
            isShowingKeyboard = true
        } label: {
            Label("Keyboard", systemImage: "keyboard")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
        }
        .buttonStyle(.bordered)
        .tint(HafaTheme.accent)
        .disabled(!isConnected)
        .accessibilityHint("Opens text entry. Focus a text field on the TV first.")
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
        accessibilityLabel: String? = nil,
        repeats: Bool = false
    ) -> some View {
        VStack(spacing: 7) {
            RemoteControlButton(
                command: command,
                systemImage: systemImage,
                accessibilityLabel: accessibilityLabel ?? label,
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

    private var recoveryMessage: String {
        if isWakingTV {
            "Wake signal sent. Hafa Remote is waiting for the TV to reconnect."
        } else if canWakeTV {
            "The TV is offline. Use the power button to turn it on, or retry the connection."
        } else {
            "Controls are paused. Reconnect once while the TV is on to enable power on."
        }
    }

    private var powerAccessibilityHint: String {
        if isConnected {
            "Asks for confirmation before turning off the TV."
        } else if canWakeTV {
            "Sends a local wake signal and reconnects when the TV responds."
        } else {
            "Unavailable until Hafa Remote reconnects while the TV is on."
        }
    }

    private func wakeTV() {
        guard !isConnected, canWakeTV, wakeTask == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isWakingTV = true
        wakeFailureMessage = nil
        wakeTask = Task { @MainActor in
            defer {
                wakeTask = nil
                isWakingTV = false
            }
            do {
                try await wakeAction()
            } catch is CancellationError {
                return
            } catch {
                wakeFailureMessage =
                    "The wake signal could not be completed. Confirm your iPhone and TV use the same Wi-Fi, enable Power On With Mobile on the TV, then try again."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

#if DEBUG
    struct RemoteControlTestHarness: View {
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        let isConnected: Bool
        @State private var lastCommand = "none"

        var body: some View {
            NavigationStack {
                RemoteControlView(
                    tvName: "Living Room TV",
                    modelName: "Q70AA",
                    statusLabel: isConnected ? "Connected" : "Offline",
                    isConnected: isConnected,
                    canWakeTV: true,
                    wakeWasVerified: false
                ) { command in
                    lastCommand = command.rawValue
                } textAction: { input in
                    lastCommand = "text:\(input.value.count)"
                } wakeAction: {
                    lastCommand = "wake"
                } retry: {
                    lastCommand = "retry"
                } showTVSetup: {
                    lastCommand = "setup"
                }
            }
            .overlay(alignment: .bottomTrailing) {
                VStack {
                    Text(lastCommand)
                        .accessibilityIdentifier("lastRemoteCommand")
                    Text(dynamicTypeSize == .accessibility5 ? "accessibility5" : "not-largest")
                        .accessibilityIdentifier("currentDynamicTypeSize")
                }
                .font(.caption2)
                .opacity(0.01)
            }
        }
    }
#endif

private struct SamsungTextInputSheet: View {
    @Environment(\.dismiss) private var dismiss

    let tvName: String
    let isConnected: Bool
    let send: @MainActor @Sendable (RemoteTextInput) async throws -> Void

    @State private var text = ""
    @State private var delivery = SamsungTextDeliveryController()
    @FocusState private var isTextFieldFocused: Bool

    private var validatedInput: RemoteTextInput? {
        try? RemoteTextInput(text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text to send", text: $text)
                        .focused($isTextFieldFocused)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .submitLabel(.send)
                        .onSubmit {
                            sendText()
                        }
                        .onChange(of: text) { _, newValue in
                            if newValue.count > RemoteTextInput.maximumCharacterCount {
                                text = String(newValue.prefix(RemoteTextInput.maximumCharacterCount))
                            }
                            delivery.clearResult()
                        }
                        .accessibilityIdentifier("remoteTextField")

                    Text("\(text.count) / \(RemoteTextInput.maximumCharacterCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel(
                            "\(text.count) of \(RemoteTextInput.maximumCharacterCount) characters")
                } header: {
                    Text("Send to \(tvName)")
                } footer: {
                    Text(
                        "Open a text field on the TV first. Some apps and secure screens do not accept remote text."
                    )
                }

                if let resultMessage = delivery.result?.message {
                    Section {
                        Label(resultMessage, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("remoteTextResult")
                    }
                }

                Section {
                    Button {
                        sendText()
                    } label: {
                        HStack {
                            Spacer()
                            if delivery.isSending {
                                ProgressView()
                            } else {
                                Text("Send Text")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(validatedInput == nil || !isConnected || delivery.isSending)
                    .accessibilityIdentifier("sendRemoteTextButton")
                }
            }
            .navigationTitle("TV Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        delivery.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                isTextFieldFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: delivery.result) { _, result in
            guard let result else { return }
            UINotificationFeedbackGenerator().notificationOccurred(result.feedbackType)
            UIAccessibility.post(notification: .announcement, argument: result.message)
        }
        .onDisappear {
            delivery.cancel()
        }
    }

    private func sendText() {
        guard let input = validatedInput, isConnected else { return }
        delivery.send(input, using: send)
    }
}

enum SamsungTextDeliveryResult: Equatable {
    case sent
    case failed

    var message: String {
        switch self {
        case .sent:
            "Sent to the TV. If nothing appeared, that TV screen does not accept remote text."
        case .failed:
            "Text was not sent. Check the TV connection and try again."
        }
    }

    var feedbackType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .sent: .success
        case .failed: .error
        }
    }
}

@MainActor
@Observable
final class SamsungTextDeliveryController {
    private(set) var isSending = false
    private(set) var result: SamsungTextDeliveryResult?

    private var activeDeliveryID: UUID?
    private var deliveryTask: Task<Void, Never>?

    func send(
        _ input: RemoteTextInput,
        using operation: @escaping @MainActor @Sendable (RemoteTextInput) async throws -> Void
    ) {
        guard deliveryTask == nil else { return }

        let deliveryID = UUID()
        activeDeliveryID = deliveryID
        isSending = true
        result = nil
        deliveryTask = Task { @MainActor [weak self] in
            do {
                try await operation(input)
                try Task.checkCancellation()
                self?.finish(deliveryID, with: .sent)
            } catch is CancellationError {
                self?.finish(deliveryID, with: nil)
            } catch {
                self?.finish(deliveryID, with: .failed)
            }
        }
    }

    func cancel() {
        activeDeliveryID = nil
        isSending = false
        let task = deliveryTask
        deliveryTask = nil
        task?.cancel()
    }

    func clearResult() {
        result = nil
    }

    private func finish(_ deliveryID: UUID, with result: SamsungTextDeliveryResult?) {
        guard activeDeliveryID == deliveryID else { return }
        activeDeliveryID = nil
        deliveryTask = nil
        isSending = false
        self.result = result
    }
}
