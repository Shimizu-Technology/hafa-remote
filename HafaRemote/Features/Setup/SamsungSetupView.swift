import SwiftUI
import UIKit

struct SamsungSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isForgettingPairing = false
    let session: RemoteSessionStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.25", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("TV IP address")
                        .accessibilityIdentifier("tvIPAddressField")
                } header: {
                    Text("TV address")
                } footer: {
                    Text("On your TV, open Settings › Network › Network Status › IP Settings.")
                }

                statusSection

                Section {
                    if session.canSendCommands {
                        Button("Open Remote") {
                            dismiss()
                        }
                        .accessibilityIdentifier("openRemoteButton")
                    }

                    Button {
                        Task {
                            await session.connect(to: address)
                        }
                    } label: {
                        HStack {
                            Text(isBusy ? "Connecting…" : "Connect to TV")
                            Spacer()
                            if isBusy {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isBusy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("connectToTVButton")

                    if canForgetPairing {
                        Button("Forget Saved Pairing and Retry", role: .destructive) {
                            Task {
                                await forgetAndRetry()
                            }
                        }
                        .disabled(isForgettingPairing)
                        .accessibilityIdentifier("forgetPairingButton")
                    }
                }
            }
            .navigationTitle("Add Samsung TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onDisappear {
                guard !session.canSendCommands else { return }
                Task {
                    await session.disconnect()
                }
            }
            .onChange(of: session.state) { _, state in
                if let announcement = accessibilityAnnouncement(for: state) {
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch session.state {
        case .idle:
            Section {
                Label("Your phone and TV must be on the same Wi-Fi network.", systemImage: "wifi")
            }
        case .connecting:
            Section {
                Label("Checking for a compatible Samsung TV…", systemImage: "magnifyingglass")
            }
        case .pairing:
            Section {
                Label("Choose Allow if your TV asks to approve Hafa Remote.", systemImage: "tv.badge.wifi")
            }
        case .connected(let tv):
            Section("Connected") {
                Label(tv.modelName, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(HafaTheme.accent)
                if let firmwareVersion = tv.firmwareVersion {
                    LabeledContent("Firmware", value: firmwareVersion)
                }
            }
        case .reconnecting(let attempt):
            Section {
                Label("Reconnecting to the TV (attempt \(attempt))…", systemImage: "arrow.clockwise")
            }
        case .offline:
            errorSection("The TV is unavailable. Make sure it is on and connected to the same Wi-Fi.")
        case .denied:
            errorSection("The TV did not approve Hafa Remote. Remove the saved pairing and approve it again.")
        case .certificateChanged:
            errorSection("The TV's security identity changed. Remove the saved pairing before reconnecting.")
        case .unsupported:
            errorSection("This TV does not support the secure pairing required by Hafa Remote.")
        case .failed(let failure):
            errorSection(failure.message)
        }
    }

    private var isBusy: Bool {
        switch session.state {
        case .connecting, .pairing, .reconnecting:
            true
        default:
            isForgettingPairing
        }
    }

    private var canForgetPairing: Bool {
        switch session.state {
        case .denied, .certificateChanged, .failed:
            !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            false
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("setupErrorMessage")
        }
    }

    private func forgetAndRetry() async {
        guard !isForgettingPairing else { return }
        isForgettingPairing = true
        defer { isForgettingPairing = false }
        do {
            try await session.forgetPairing(for: address)
            await session.connect(to: address)
        } catch {
            UIAccessibility.post(
                notification: .announcement,
                argument: "The saved pairing could not be removed. Check the TV address and try again."
            )
        }
    }

    private func accessibilityAnnouncement(for state: RemoteSessionState) -> String? {
        switch state {
        case .pairing:
            "Choose Allow if your TV asks to approve Hafa Remote."
        case .connected(let tv):
            "Connected to \(tv.modelName)."
        case .denied:
            "The TV did not approve Hafa Remote."
        case .certificateChanged:
            "The TV's security identity changed. Remove the saved pairing before reconnecting."
        case .unsupported:
            "This TV is not supported."
        case .offline:
            "The TV is unavailable."
        case .failed(let failure):
            failure.message
        case .idle, .connecting, .reconnecting:
            nil
        }
    }
}

#Preview {
    SamsungSetupView(session: RemoteSessionStore())
}
