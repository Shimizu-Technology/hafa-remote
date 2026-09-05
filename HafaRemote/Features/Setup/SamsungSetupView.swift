import SwiftUI
import UIKit

struct SamsungSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isForgettingPairing = false
    @State private var connectionTaskID: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var repairTaskID: UUID?
    @State private var repairTask: Task<Void, Never>?
    let session: RemoteSessionStore

    init(session: RemoteSessionStore, initialAddress: String = "") {
        self.session = session
        _address = State(initialValue: initialAddress)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.25", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isBusy)
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
                        let operationID = UUID()
                        connectionTaskID = nil
                        connectionTask?.cancel()
                        let requestedAddress = address
                        connectionTaskID = operationID
                        connectionTask = Task {
                            await session.connect(to: requestedAddress)
                            guard connectionTaskID == operationID else { return }
                            connectionTaskID = nil
                            connectionTask = nil
                        }
                    } label: {
                        HStack {
                            Text(
                                isForgettingPairing
                                    ? "Removing saved pairing…"
                                    : isBusy ? "Connecting…" : "Connect to TV"
                            )
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
                            let operationID = UUID()
                            let requestedAddress = address
                            repairTaskID = nil
                            repairTask?.cancel()
                            repairTaskID = operationID
                            repairTask = Task {
                                await forgetAndRetry(for: requestedAddress)
                                guard repairTaskID == operationID else { return }
                                repairTaskID = nil
                                repairTask = nil
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
                connectionTaskID = nil
                connectionTask?.cancel()
                connectionTask = nil
                repairTaskID = nil
                repairTask?.cancel()
                repairTask = nil
                guard !session.canSendCommands else { return }
                Task {
                    await session.disconnect(clearRememberedTV: false)
                }
            }
            .onAppear {
                guard address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                address = session.lastConnectedTV?.address.rawValue ?? ""
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
            errorSection("The TV did not approve Hafa Remote. Try again and choose Allow on the TV.")
        case .savedPairingRejected:
            errorSection(
                "The TV no longer accepts its saved pairing. Remove it and approve Hafa Remote again.")
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
        case .savedPairingRejected, .certificateChanged:
            !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .failed(.timedOut(.forgetPairing)):
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

    private func forgetAndRetry(for address: String) async {
        guard !isForgettingPairing else { return }
        isForgettingPairing = true
        defer { isForgettingPairing = false }
        do {
            try await session.forgetPairing(for: address)
            try Task.checkCancellation()
            await session.connect(to: address)
        } catch is CancellationError {
            return
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
        case .savedPairingRejected:
            "The TV no longer accepts its saved pairing. Remove it before reconnecting."
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
