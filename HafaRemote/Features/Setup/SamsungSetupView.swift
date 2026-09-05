import SwiftUI
import UIKit

struct TVSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var discovery: TVDiscoveryStore
    @State private var address = ""
    @State private var selectedTV: DiscoveredTV?
    @State private var isShowingManualSetup = false
    @State private var isForgettingPairing = false
    @State private var connectionTaskID: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var repairTaskID: UUID?
    @State private var recoveryTask: Task<Void, Never>?
    @State private var repairTask: Task<Void, Never>?
    @State private var pairingCode = ""
    @State private var isSubmittingPairingCode = false
    @State private var hasSubmittedPairingCode = false
    @State private var pairingCodeTask: Task<Void, Never>?
    let session: RemoteSessionStore
    let initialAddress: String
    let initialReportedDeviceID: String?

    init(
        session: RemoteSessionStore,
        initialAddress: String = "",
        initialReportedDeviceID: String? = nil,
        discovery: TVDiscoveryStore = TVDiscoveryStore()
    ) {
        self.session = session
        self.initialAddress = initialAddress
        self.initialReportedDeviceID = initialReportedDeviceID
        _address = State(initialValue: initialAddress)
        _discovery = State(initialValue: discovery)
    }

    var body: some View {
        NavigationStack {
            Form {
                discoverySection
                connectionStatusSection
                manualSetupSection
            }
            .navigationTitle("Add TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                discovery.start()
            }
            .onAppear {
                preparePairingRepairIfNeeded(for: session.state)
            }
            .onDisappear {
                discovery.stop()
                connectionTaskID = nil
                connectionTask?.cancel()
                connectionTask = nil
                repairTaskID = nil
                recoveryTask?.cancel()
                recoveryTask = nil
                repairTask?.cancel()
                repairTask = nil
                pairingCodeTask?.cancel()
                pairingCodeTask = nil
                guard !session.canSendCommands else { return }
                Task {
                    await session.disconnect(clearRememberedTV: false)
                }
            }
            .onChange(of: discovery.state) { _, state in
                if let announcement = discoveryAnnouncement(for: state) {
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
            .onChange(of: discovery.televisions.count) { _, count in
                guard count > 0 else { return }
                let announcement = count == 1 ? "Found one TV." : "Found \(count) TVs."
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
            .onChange(of: session.state) { _, state in
                if case .pairing = state {
                    // Preserve entered digits while the Sony handshake is waiting.
                } else {
                    pairingCode = ""
                    isSubmittingPairingCode = false
                    hasSubmittedPairingCode = false
                }
                preparePairingRepairIfNeeded(for: state)
                if let announcement = accessibilityAnnouncement(for: state) {
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
                if case .connected = state {
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var discoverySection: some View {
        switch discovery.state {
        case .idle, .searching:
            Section {
                VStack(spacing: 18) {
                    Image(systemName: "tv.badge.wifi")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(HafaTheme.accent)
                        .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text("Looking for TVs…")
                            .font(.headline)
                        Text("Keep your TV on and connected to the same home Wi-Fi as this iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(HafaTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }

                    ProgressView()
                        .tint(HafaTheme.accent)
                        .accessibilityLabel("Searching for nearby TVs")
                        .accessibilityIdentifier("tvDiscoveryProgress")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

        case .results:
            Section {
                ForEach(discovery.televisions) { television in
                    Button {
                        connect(to: television)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "tv")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(HafaTheme.accent)
                                .frame(width: 42, height: 42)
                                .background(
                                    HafaTheme.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(television.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(television.brand.displayName) · \(television.modelName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityLabel(
                        "\(television.displayName), \(television.brand.displayName), \(television.modelName)"
                    )
                    .accessibilityHint("Connects Hafa Remote to this TV")
                    .accessibilityIdentifier("discoveredTVButton")
                }
            } header: {
                Text("Nearby TVs")
            } footer: {
                Text("Tap your TV, then follow the pairing instructions.")
            }

        case .noResults:
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label("No supported TVs found", systemImage: "tv.slash")
                        .font(.headline)

                    Text("Check that the TV is on and that neither device is using a guest Wi-Fi network.")
                        .font(.subheadline)
                        .foregroundStyle(HafaTheme.secondaryText)

                    Button("Scan Again", systemImage: "arrow.clockwise") {
                        discovery.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HafaTheme.accent)
                    .foregroundStyle(HafaTheme.canvas)
                    .accessibilityIdentifier("scanAgainButton")
                }
                .padding(.vertical, 8)
            }

        case .permissionDenied:
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Local Network access is off", systemImage: "wifi.exclamationmark")
                        .font(.headline)

                    Text(
                        "Allow Local Network access so Hafa Remote can find TVs in your home. Nothing is sent to Shimizu Technology."
                    )
                    .font(.subheadline)
                    .foregroundStyle(HafaTheme.secondaryText)

                    Button("Open iPhone Settings", systemImage: "gear") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HafaTheme.accent)
                    .foregroundStyle(HafaTheme.canvas)
                }
                .padding(.vertical, 8)
            }

        case .failed:
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label("TV search stopped", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(
                        "Hafa Remote could not search this Wi-Fi network. Try again or use the troubleshooting option below."
                    )
                    .font(.subheadline)
                    .foregroundStyle(HafaTheme.secondaryText)
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        discovery.start()
                    }
                    .accessibilityIdentifier("scanAgainButton")
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var connectionStatusSection: some View {
        switch session.state {
        case .idle:
            EmptyView()
        case .connecting:
            Section {
                Label("Connecting to \(selectedTV?.displayName ?? "TV")…", systemImage: "wifi")
            }
        case .pairing:
            Section {
                if selectedTV?.brand == .sony {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Enter the code shown on your Sony TV.", systemImage: "number")
                            .font(.headline)

                        TextField("6-character code", text: $pairingCode)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                            .onChange(of: pairingCode) { _, value in
                                pairingCode = sanitizedPairingCode(value)
                            }
                            .accessibilityLabel("Sony TV pairing code")
                            .accessibilityIdentifier("sonyPairingCodeField")

                        Button {
                            submitSonyPairingCode()
                        } label: {
                            HStack {
                                Text(hasSubmittedPairingCode ? "Code Submitted" : "Pair Sony TV")
                                Spacer()
                                if isSubmittingPairingCode {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(
                            pairingCode.count != 6 || isSubmittingPairingCode
                                || hasSubmittedPairingCode
                        )
                        .accessibilityIdentifier("submitSonyPairingCodeButton")
                    }
                } else {
                    Label(
                        "Choose Allow if your TV asks to approve Hafa Remote.",
                        systemImage: "tv.badge.wifi"
                    )
                }
            }
        case .connected:
            EmptyView()
        case .reconnecting(let attempt):
            Section {
                Label("Reconnecting to the TV (attempt \(attempt))…", systemImage: "arrow.clockwise")
            }
        case .offline:
            connectionErrorSection(
                "The TV is unavailable. Make sure it is on and connected to the same Wi-Fi.")
        case .denied:
            connectionErrorSection(
                selectedTV?.brand == .sony
                    ? "The Sony pairing code was not accepted. Find the TV and try again."
                    : "The TV did not approve Hafa Remote. Try again and choose Allow on the TV."
            )
        case .savedPairingRejected:
            connectionErrorSection(
                "The TV no longer accepts its saved pairing. Remove it and approve Hafa Remote again.")
        case .certificateChanged:
            connectionErrorSection(
                "The TV's security identity changed. Remove the saved pairing before reconnecting.")
        case .unsupported:
            connectionErrorSection("This TV does not support the secure pairing required by Hafa Remote.")
        case .failed(let failure):
            connectionErrorSection(failure.message)
        }
    }

    private var manualSetupSection: some View {
        Section {
            Button {
                if accessibilityReduceMotion {
                    isShowingManualSetup.toggle()
                } else {
                    withAnimation {
                        isShowingManualSetup.toggle()
                    }
                }
            } label: {
                HStack {
                    Label("TV not showing up?", systemImage: "network")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isShowingManualSetup ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("manualSetupButton")
            .accessibilityValue(isShowingManualSetup ? "Expanded" : "Collapsed")

            if isShowingManualSetup {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "As a troubleshooting fallback, enter the private TV address shown under Settings › Network › Network Status › IP Settings."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    TextField("192.168.1.25", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isBusy)
                        .accessibilityLabel("TV IP address")
                        .accessibilityIdentifier("tvIPAddressField")

                    Button {
                        connectManually()
                    } label: {
                        HStack {
                            Text(
                                isForgettingPairing
                                    ? "Removing saved pairing…"
                                    : isBusy ? "Connecting…" : "Connect with TV Address"
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

    private func preparePairingRepairIfNeeded(for state: RemoteSessionState) {
        switch state {
        case .savedPairingRejected, .certificateChanged:
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                address = session.lastConnectedTV?.address.rawValue ?? ""
            }
            if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isShowingManualSetup = true
            }
        default:
            return
        }
    }

    private func connect(to television: DiscoveredTV) {
        selectedTV = television
        pairingCode = ""
        hasSubmittedPairingCode = false
        address = television.address.rawValue
        discovery.stop()
        connect(to: television.connectionTarget)
    }

    private func connectManually() {
        selectedTV = nil
        pairingCode = ""
        hasSubmittedPairingCode = false
        discovery.stop()
        connectUsingCurrentAddress()
    }

    private func connect(to target: TVConnectionTarget) {
        let operationID = UUID()
        connectionTaskID = nil
        connectionTask?.cancel()
        connectionTaskID = operationID
        connectionTask = Task {
            await session.connect(to: target)
            guard connectionTaskID == operationID else { return }
            connectionTaskID = nil
            connectionTask = nil
        }
    }

    private func connectUsingCurrentAddress() {
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
    }

    private func connectionErrorSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("setupErrorMessage")

                Button("Find TVs Again", systemImage: "arrow.clockwise") {
                    connectionTask?.cancel()
                    recoveryTask?.cancel()
                    recoveryTask = Task {
                        await session.disconnect(clearRememberedTV: false)
                        guard !Task.isCancelled else { return }
                        discovery.start()
                    }
                }
            }
        }
    }

    private func sanitizedPairingCode(_ value: String) -> String {
        String(
            value.uppercased().filter { $0.isHexDigit }.prefix(6)
        )
    }

    private func submitSonyPairingCode() {
        guard pairingCode.count == 6, !isSubmittingPairingCode, !hasSubmittedPairingCode else {
            return
        }
        pairingCodeTask?.cancel()
        isSubmittingPairingCode = true
        let submittedCode = pairingCode
        pairingCodeTask = Task {
            do {
                try await session.submitPairingCode(submittedCode)
                guard !Task.isCancelled else { return }
                hasSubmittedPairingCode = true
            } catch is CancellationError {
                return
            } catch {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "The pairing code could not be submitted. Try again."
                )
            }
            isSubmittingPairingCode = false
            pairingCodeTask = nil
        }
    }

    private func forgetAndRetry(for address: String) async {
        guard !isForgettingPairing else { return }
        isForgettingPairing = true
        defer { isForgettingPairing = false }
        do {
            try await session.forgetPairing(
                for: address,
                reportedDeviceID: address == initialAddress ? initialReportedDeviceID : nil
            )
            try Task.checkCancellation()
            await session.connect(to: address)
        } catch is CancellationError {
            return
        } catch {
            UIAccessibility.post(
                notification: .announcement,
                argument: "The saved pairing could not be removed. Find the TV again and retry."
            )
        }
    }

    private func discoveryAnnouncement(for state: TVDiscoveryState) -> String? {
        switch state {
        case .noResults:
            return "No supported TVs were found."
        case .permissionDenied:
            return "Local Network access is off."
        case .failed:
            return "TV search stopped."
        case .idle, .searching, .results:
            return nil
        }
    }

    private func accessibilityAnnouncement(for state: RemoteSessionState) -> String? {
        switch state {
        case .pairing:
            selectedTV?.brand == .sony
                ? "Enter the six-character code shown on your Sony TV."
                : "Choose Allow if your TV asks to approve Hafa Remote."
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
    TVSetupView(session: RemoteSessionStore())
}
