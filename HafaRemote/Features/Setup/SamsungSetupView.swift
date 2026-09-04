import SwiftUI
import UIKit

struct SamsungSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SamsungSetupViewModel

    init(model: SamsungSetupViewModel? = nil) {
        _model = State(initialValue: model ?? SamsungSetupViewModel())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.25", text: $model.address)
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
                    Button {
                        Task {
                            await model.connect()
                        }
                    } label: {
                        HStack {
                            Text(model.isConnecting ? "Connecting…" : "Connect to TV")
                            Spacer()
                            if model.isBusy {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isBusy || model.address.isEmpty)
                    .accessibilityIdentifier("connectToTVButton")

                    if model.isControllable {
                        Button("Send Select Test") {
                            Task {
                                await model.sendSelect()
                            }
                        }
                        .accessibilityHint("Sends the center button once to confirm control works.")
                        .accessibilityIdentifier("sendSelectTestButton")
                    }

                    if case .failed(_, true) = model.status {
                        Button("Forget Saved Pairing and Retry", role: .destructive) {
                            Task {
                                await model.forgetAndRetry()
                            }
                        }
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
                Task {
                    await model.disconnect()
                }
            }
            .onChange(of: model.status) { _, status in
                if let announcement = accessibilityAnnouncement(for: status) {
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.status {
        case .idle:
            Section {
                Label("Your phone and TV must be on the same Wi-Fi network.", systemImage: "wifi")
            }
        case .checking:
            Section {
                Label("Checking for a compatible Samsung TV…", systemImage: "magnifyingglass")
            }
        case .waitingForApproval:
            Section {
                Label("Choose Allow if your TV asks to approve Hafa Remote.", systemImage: "tv.badge.wifi")
            }
        case .connected(let tv), .commandSent(let tv):
            Section("Connected") {
                Label(tv.modelName, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(HafaTheme.accent)
                if let firmwareVersion = tv.firmwareVersion {
                    LabeledContent("Firmware", value: firmwareVersion)
                }
                if case .commandSent = model.status {
                    Label("Select sent", systemImage: "checkmark")
                        .foregroundStyle(HafaTheme.accent)
                }
            }
        case .failed(let message, _):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("setupErrorMessage")
            }
        }
    }

    private func accessibilityAnnouncement(for status: SamsungSetupViewModel.Status) -> String? {
        switch status {
        case .waitingForApproval:
            "Choose Allow if your TV asks to approve Hafa Remote."
        case .connected(let tv):
            "Connected to \(tv.modelName)."
        case .commandSent:
            "Select sent."
        case .failed(let message, _):
            message
        case .idle, .checking:
            nil
        }
    }
}

#Preview {
    SamsungSetupView()
}
