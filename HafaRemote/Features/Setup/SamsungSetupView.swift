import SwiftData
import SwiftUI
import UIKit

struct TVSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Query private var savedTVs: [SavedTV]
    @State private var discovery: TVDiscoveryStore
    @State private var discoveryCollection: DiagnosticCollectionToken?
    @State private var address = ""
    @State private var manualBrand: TVBrand = .samsung
    @State private var manualFailure: String?
    @State private var selectedTV: DiscoveredTV?
    @State private var ambiguousCandidate: DiscoveredTV?
    @State private var ambiguousSavedTVs: [SavedTV] = []
    @State private var isChoosingSavedTV = false
    @State private var selectedBrand: TVBrand?
    @State private var selectedTarget: TVConnectionTarget?
    @State private var isShowingManualSetup = false
    @State private var isShowingHelp = false
    @State private var isForgettingPairing = false
    @State private var connectionTaskID: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var repairTaskID: UUID?
    @State private var recoveryTask: Task<Void, Never>?
    @State private var repairTask: Task<Void, Never>?
    @State private var pairingCode = ""
    @State private var isSubmittingPairingCode = false
    @State private var hasSubmittedPairingCode = false
    @State private var pairingCodeSubmissionID: UUID?
    @State private var pairingCodeTask: Task<Void, Never>?
    let session: RemoteSessionStore
    let initialAddress: String
    let initialReportedDeviceID: String?
    let initialTarget: TVConnectionTarget?

    init(
        session: RemoteSessionStore,
        initialAddress: String = "",
        initialReportedDeviceID: String? = nil,
        initialTarget: TVConnectionTarget? = nil,
        discovery: TVDiscoveryStore = TVDiscoveryStore()
    ) {
        self.session = session
        self.initialTarget = initialTarget
        self.initialAddress = initialTarget?.address.rawValue ?? initialAddress
        self.initialReportedDeviceID =
            initialTarget?.expectedSavedDeviceID ?? initialTarget?.reportedDeviceID ?? initialReportedDeviceID
        _address = State(initialValue: initialTarget?.address.rawValue ?? initialAddress)
        _selectedBrand = State(initialValue: initialTarget?.brand)
        _manualBrand = State(initialValue: initialTarget?.brand ?? .samsung)
        _selectedTarget = State(initialValue: initialTarget)
        _discovery = State(initialValue: discovery)
    }

    var body: some View {
        NavigationStack {
            Form {
                discoverySection
                connectionStatusSection
                if !requiresSavedTVManagement { manualSetupSection }
            }
            .scrollContentBackground(.hidden)
            .background(HafaTheme.canvas)
            .tint(HafaTheme.accent)
            .navigationTitle("Add TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Help", systemImage: "questionmark.circle") {
                        isShowingHelp = true
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("setupHelpButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Choose the saved TV", isPresented: $isChoosingSavedTV, titleVisibility: .visible
            ) {
                ForEach(ambiguousSavedTVs) { saved in
                    Button(savedTVChoiceLabel(saved)) {
                        guard let candidate = ambiguousCandidate else { return }
                        beginConnection(
                            to: candidate,
                            target: candidate.connectionTarget.expectingSavedIdentity(saved.reportedDeviceID)
                        )
                        ambiguousCandidate = nil
                        ambiguousSavedTVs = []
                    }
                }
                Button("Cancel", role: .cancel) {
                    ambiguousCandidate = nil
                    ambiguousSavedTVs = []
                }
            } message: {
                Text(
                    "More than one saved TV matches this discovery name. Choose the TV you intend to control. Its saved security identity will still be checked."
                )
            }
            .sheet(isPresented: $isShowingHelp) {
                HafaRemoteHelpView()
            }
            .task {
                startDiscovery()
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
                resetPairingCodeSubmission()
                guard !session.canSendCommands else { return }
                Task {
                    await session.disconnect(clearRememberedTV: false)
                }
            }
            .onChange(of: discovery.state) { _, state in
                if state == .noResults || state == .permissionDenied || state == .failed {
                    session.diagnostics.record(.discoveryFinished, collection: discoveryCollection)
                }
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
                    // Preserve entered digits while the selected TV is waiting.
                } else {
                    resetPairingCodeSubmission()
                    pairingCode = ""
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
        .tint(HafaTheme.accent)
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
                        Text(
                            "Keep your TV on and on the same home network. This iPhone uses Wi-Fi; your TV can use Wi-Fi or Ethernet."
                        )
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

                    Text(
                        "No compatible TV responded. Check that the TV is on, on the same home network, and not isolated by guest Wi-Fi."
                    )
                    .font(.subheadline)
                    .foregroundStyle(HafaTheme.secondaryText)

                    Button("Scan Again", systemImage: "arrow.clockwise") {
                        startDiscovery()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HafaTheme.accent)
                    .foregroundStyle(HafaTheme.onAccent)
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
                    .foregroundStyle(HafaTheme.onAccent)
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
                        startDiscovery()
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
                if let brand = selectedBrand, brand == .sony || brand == .vizio {
                    pairingCodeEntry(for: brand)
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
                "The TV did not respond. Make sure it is on and connected to the same home network.")
        case .denied:
            connectionErrorSection(pairingDeniedMessage)
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
                // Keep controls as separate Form rows. A stacked menu Picker can otherwise
                // claim the hit area of neighboring text fields and repair actions.
                Group {
                    Text(
                        "Choose the TV brand, then enter its private address from the TV network settings. Samsung asks for approval, Sony shows a pairing code, and Vizio shows a PIN."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Picker("TV Brand", selection: $manualBrand) {
                        ForEach(TVBrand.allCases, id: \.self) { brand in Text(brand.displayName).tag(brand) }
                    }
                    .disabled(isBusy)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("manualTVBrandPicker")
                    if let manualFailure { Text(manualFailure).foregroundStyle(.secondary) }
                    TextField("192.168.1.25", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isBusy)
                        .frame(minHeight: 44)
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
                        .frame(minHeight: 44)
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
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("forgetPairingButton")
                    }
                }
            }
        }
    }

    private var pairingDeniedMessage: String {
        switch selectedBrand {
        case .sony:
            "The Sony pairing code was not accepted. Find the TV and try again."
        case .vizio:
            "The Vizio PIN was not accepted. Find the TV and try again."
        case .samsung, .none:
            "The TV did not approve Hafa Remote. Try again and choose Allow on the TV."
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

    private var requiresSavedTVManagement: Bool {
        SavedTVPairingRecovery.requiresManagement(
            state: session.state, target: selectedTarget ?? initialTarget
        )
    }

    private var canForgetPairing: Bool {
        guard !requiresSavedTVManagement else { return false }
        return switch session.state {
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
            guard !requiresSavedTVManagement else { return }
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

    private func startDiscovery() {
        discoveryCollection = session.diagnostics.captureCollection()
        session.diagnostics.record(.discoveryStarted, collection: discoveryCollection)
        discovery.start()
    }

    private func connect(to television: DiscoveredTV) {
        switch SavedTVDiscoveryAssociation.resolve(television, savedTVs: savedTVs) {
        case .newCandidate(let target), .saved(let target):
            beginConnection(to: television, target: target)
        case .requiresChoice(let matches):
            ambiguousCandidate = television
            ambiguousSavedTVs = matches
            isChoosingSavedTV = true
        }
    }

    private func savedTVChoiceLabel(_ saved: SavedTV) -> String {
        [saved.displayName, saved.roomName, saved.modelName].compactMap { $0 }.joined(separator: " • ")
    }

    private func beginConnection(to television: DiscoveredTV, target: TVConnectionTarget) {
        resetPairingCodeSubmission()
        selectedTV = television
        selectedBrand = television.brand
        manualBrand = television.brand
        selectedTarget = target
        pairingCode = ""
        hasSubmittedPairingCode = false
        address = television.address.rawValue
        discovery.stop()
        connect(to: target)
    }

    private func connectManually() {
        resetPairingCodeSubmission()
        selectedTV = nil
        selectedBrand = manualBrand
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
        do {
            let validated = try PrivateIPv4Address(address.trimmingCharacters(in: .whitespacesAndNewlines))
            let target = ManualTVTargetFactory.target(
                address: validated, brand: manualBrand, savedTarget: selectedTarget ?? initialTarget)
            selectedBrand = manualBrand
            selectedTarget = target
            manualFailure = nil
            connect(to: target)
        } catch {
            manualFailure =
                (error as? PrivateIPv4AddressError)?.errorDescription
                ?? "Enter the TV's private network address."
        }
    }

    private func connectionErrorSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(HafaTheme.warning)
                    .accessibilityIdentifier("setupErrorMessage")

                if requiresSavedTVManagement {
                    Text(
                        "Close setup, open My TVs, and forget only this TV. Then choose Add TV to approve it again."
                    )
                    .accessibilityIdentifier("savedTVManagementRecoveryMessage")
                    Button("Close Setup") { dismiss() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("closeSetupForSavedTVManagement")
                }

                Button("Find TVs Again", systemImage: "arrow.clockwise") {
                    connectionTask?.cancel()
                    recoveryTask?.cancel()
                    recoveryTask = Task {
                        await session.disconnect(clearRememberedTV: false)
                        guard !Task.isCancelled else { return }
                        startDiscovery()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pairingCodeEntry(for brand: TVBrand) -> some View {
        let isSony = brand == .sony
        let requiredLength = isSony ? 6 : 4
        let fieldIdentifier = isSony ? "sonyPairingCodeField" : "vizioPairingCodeField"
        let buttonIdentifier =
            isSony ? "submitSonyPairingCodeButton" : "submitVizioPairingCodeButton"

        VStack(alignment: .leading, spacing: 14) {
            Label(
                isSony
                    ? "Enter the code shown on your Sony TV."
                    : "Enter the PIN shown on your Vizio TV.",
                systemImage: "number"
            )
            .font(.headline)

            TextField(isSony ? "6-character code" : "4-digit PIN", text: $pairingCode)
                .keyboardType(isSony ? .asciiCapable : .numberPad)
                .textInputAutocapitalization(isSony ? .characters : .never)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .onChange(of: pairingCode) { _, value in
                    pairingCode = sanitizedPairingCode(value, for: brand)
                }
                .accessibilityLabel("\(brand.displayName) TV pairing code")
                .accessibilityIdentifier(fieldIdentifier)

            Button {
                submitPairingCode(requiredLength: requiredLength)
            } label: {
                HStack {
                    Text(
                        hasSubmittedPairingCode
                            ? "Code Submitted" : "Pair \(brand.displayName) TV"
                    )
                    Spacer()
                    if isSubmittingPairingCode {
                        ProgressView()
                    }
                }
            }
            .disabled(
                pairingCode.count != requiredLength || isSubmittingPairingCode
                    || hasSubmittedPairingCode
            )
            .accessibilityIdentifier(buttonIdentifier)
        }
    }

    private func sanitizedPairingCode(_ value: String, for brand: TVBrand) -> String {
        switch brand {
        case .sony:
            String(value.uppercased().filter(\.isHexDigit).prefix(6))
        case .vizio:
            String(value.filter(\.isNumber).prefix(4))
        case .samsung:
            ""
        }
    }

    private func submitPairingCode(requiredLength: Int) {
        guard pairingCode.count == requiredLength,
            !isSubmittingPairingCode,
            !hasSubmittedPairingCode
        else {
            return
        }
        pairingCodeTask?.cancel()
        isSubmittingPairingCode = true
        let submittedCode = pairingCode
        let operationID = UUID()
        pairingCodeSubmissionID = operationID
        pairingCodeTask = Task {
            defer {
                if pairingCodeSubmissionID == operationID {
                    pairingCodeSubmissionID = nil
                    isSubmittingPairingCode = false
                    pairingCodeTask = nil
                }
            }
            do {
                try await session.submitPairingCode(submittedCode)
                guard !Task.isCancelled, pairingCodeSubmissionID == operationID else { return }
                hasSubmittedPairingCode = true
            } catch is CancellationError {
                return
            } catch {
                guard pairingCodeSubmissionID == operationID else { return }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "The pairing code could not be submitted. Try again."
                )
            }
        }
    }

    private func resetPairingCodeSubmission() {
        pairingCodeSubmissionID = nil
        pairingCodeTask?.cancel()
        pairingCodeTask = nil
        isSubmittingPairingCode = false
    }

    private func forgetAndRetry(for address: String) async {
        guard !isForgettingPairing else { return }
        isForgettingPairing = true
        defer { isForgettingPairing = false }
        let repairTarget = [selectedTarget, initialTarget]
            .compactMap { $0 }
            .first(where: { $0.address.rawValue == address })
        let repairBrand = repairTarget?.brand ?? selectedBrand ?? .samsung
        selectedBrand = repairBrand
        do {
            try await session.forgetPairing(
                for: address,
                reportedDeviceID:
                    repairTarget?.expectedSavedDeviceID ?? repairTarget?.reportedDeviceID
                    ?? (address == initialAddress ? initialReportedDeviceID : nil),
                brand: repairBrand
            )
            try Task.checkCancellation()
            if let repairTarget {
                await session.connect(to: repairTarget)
            } else {
                let endpoint = try PrivateIPv4Address(address.trimmingCharacters(in: .whitespacesAndNewlines))
                let target = ManualTVTargetFactory.target(address: endpoint, brand: repairBrand)
                await session.connect(to: target)
            }
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
            switch selectedBrand {
            case .sony:
                "Enter the six-character code shown on your Sony TV."
            case .vizio:
                "Enter the four-digit PIN shown on your Vizio TV."
            case .samsung, .none:
                "Choose Allow if your TV asks to approve Hafa Remote."
            }
        case .connected(let tv):
            "Connected to \(tv.modelName)."
        case .denied:
            pairingDeniedMessage
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

enum SavedTVPairingRecovery {
    static func requiresManagement(state: RemoteSessionState, target: TVConnectionTarget?) -> Bool {
        guard target?.expectedSavedDeviceID != nil else { return false }
        switch state {
        case .savedPairingRejected, .certificateChanged: return true
        default: return false
        }
    }
}

/// Discovery metadata may locate a saved TV, but never becomes its security identity.
@MainActor
enum SavedTVDiscoveryAssociation {
    case newCandidate(TVConnectionTarget)
    case saved(TVConnectionTarget)
    case requiresChoice([SavedTV])

    static func resolve(_ candidate: DiscoveredTV, savedTVs: [SavedTV]) -> Self {
        let matches = savedTVs.filter { saved in
            guard saved.brand == candidate.brand, !saved.pendingCredentialRemoval else { return false }
            let aliasMatches = saved.discoveryIdentifier == candidate.reportedIdentifier
            // Sony's advertisement hash has the shape of a certificate fingerprint;
            // only an alias persisted after authentication may associate those records.
            let stableIDMatches =
                candidate.brand != .sony
                && saved.reportedDeviceID == candidate.reportedIdentifier
            return aliasMatches || stableIDMatches
        }
        guard let saved = matches.first else { return .newCandidate(candidate.connectionTarget) }
        guard matches.count == 1 else { return .requiresChoice(matches) }
        return .saved(candidate.connectionTarget.expectingSavedIdentity(saved.reportedDeviceID))
    }
}

#Preview {
    TVSetupView(session: RemoteSessionStore())
        .modelContainer(for: SavedTV.self, inMemory: true)
}
