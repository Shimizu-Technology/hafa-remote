import SwiftData
import SwiftUI

/// Owns the user-facing flow from first launch through active remote control.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \SavedTV.lastUsedAt, order: .reverse) private var savedTVs: [SavedTV]
    @State private var session: RemoteSessionStore
    @State private var discovery: TVDiscoveryStore
    @State private var networkMonitor = LocalNetworkMonitor()
    @State private var isShowingSetup = false
    @State private var isShowingMyTVs = false
    @State private var scenePhaseEvents = ScenePhaseEvents()
    @State private var restoration = SavedTVRestorationCoordinator()
    @State private var selection = SavedTVSelectionCoordinator()
    @State private var alert: HomeAlert?
    @State private var pendingWakeAttempt: PendingWakeAttempt?

    private let wakeService: any SamsungTVWaking

    init(
        session: RemoteSessionStore = RemoteSessionStore(),
        discovery: TVDiscoveryStore = TVDiscoveryStore(),
        wakeService: any SamsungTVWaking = SamsungWakeOnLANService()
    ) {
        _session = State(initialValue: session)
        _discovery = State(initialValue: discovery)
        self.wakeService = wakeService
    }

    /// Builds the current saved-TV, restoration, setup, or remote presentation.
    var body: some View {
        NavigationStack {
            if let tv = presentedTV {
                let savedTV = savedTV(for: tv)
                RemoteControlView(
                    tvName: displayName(for: tv),
                    modelName: tv.modelName,
                    statusLabel: statusLabel,
                    isConnected: isPresentedTVConnected,
                    supportsTextInput: tv.brand == .samsung,
                    canPowerOnTV: canPowerOn(tv, savedTV: savedTV),
                    powerOnWasVerified: savedTV?.wakeWasVerified ?? false,
                    powerOnHelpText: powerOnHelpText(for: tv.brand),
                    powerOnFailureText: powerOnFailureText(for: tv.brand),
                    powerOffFailureText: powerOffFailureText(for: tv.brand)
                ) { command in
                    guard isPresentedTVConnected else { return }
                    do {
                        try await session.send(command)
                    } catch {
                        // The session projects the protocol failure and reconnect state.
                    }
                } textAction: { input in
                    guard isPresentedTVConnected else {
                        throw TVSelectionError.notConnected
                    }
                    try await session.sendText(input)
                } powerOnAction: {
                    try await powerOn(tv, savedTV: savedTV)
                } powerOffAction: {
                    guard isPresentedTVConnected else {
                        throw TVSelectionError.notConnected
                    }
                    try await session.send(.powerOff)
                    try Task.checkCancellation()
                    await session.disconnect(clearRememberedTV: false)
                } retry: {
                    await session.connect(to: tv.connectionTarget)
                } showTVSetup: {
                    isShowingSetup = true
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        myTVsButton
                    }
                }
            } else if restoration.isRestoring {
                restoringState
            } else {
                emptyState
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSetup) {
            TVSetupView(
                session: session,
                initialAddress:
                    presentedTV?.address.rawValue
                    ?? savedTVs.first?.lastKnownAddress
                    ?? "",
                initialReportedDeviceID:
                    presentedTV?.reportedDeviceID
                    ?? savedTVs.first?.reportedDeviceID,
                initialTarget:
                    presentedTV?.connectionTarget
                    ?? savedTVs.first?.connectionTarget,
                discovery: discovery
            )
        }
        .sheet(isPresented: $isShowingMyTVs) {
            MyTVsView(
                savedTVs: savedTVs,
                selectedDeviceKey: selection.selectedDeviceKey,
                connectedDeviceKey: session.connectedTV?.stableDeviceKey,
                isSwitching: selection.isSwitching,
                selectTV: { savedTV in
                    select(savedTV)
                    isShowingMyTVs = false
                },
                addTV: {
                    isShowingMyTVs = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        isShowingSetup = true
                    }
                },
                forgetTV: { savedTV in
                    try await forget(savedTV)
                }
            )
        }
        .alert(
            alert?.title ?? "Hafa Remote",
            isPresented: Binding(
                get: { alert != nil },
                set: { if !$0 { alert = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert?.message ?? "")
        }
        .task(id: savedTVs.first?.persistentModelID) {
            backfillLegacySavedTVsIfNeeded()
            await restoreLastUsedTVIfNeeded()
        }
        .onChange(of: session.state) { _, state in
            guard case .connected(let tv) = state else { return }
            saveConnectedTV(tv)
        }
        .onChange(of: networkMonitor.isReachable) { _, isReachable in
            guard let isReachable else { return }
            Task {
                await session.networkReachabilityChanged(isReachable: isReachable)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            scenePhaseEvents.continuation.yield(phase)
        }
        .task {
            for await phase in scenePhaseEvents.stream {
                switch phase {
                case .background:
                    await session.applicationDidEnterBackground()
                case .active:
                    await session.applicationWillEnterForeground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private var emptyState: some View {
        ZStack {
            HafaTheme.canvas
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 28) {
                        Spacer(minLength: 24)

                        Image(systemName: "tv")
                            .font(.system(size: 50, weight: .medium))
                            .foregroundStyle(HafaTheme.accent)
                            .accessibilityHidden(true)

                        VStack(spacing: 10) {
                            Text("Your remote, without the rental fee.")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)

                            Text(
                                "Connect a supported TV on this Wi-Fi network. No account, ads, or subscription."
                            )
                            .font(.body)
                            .foregroundStyle(HafaTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        }

                        Button {
                            isShowingSetup = true
                        } label: {
                            Label("Add TV", systemImage: "plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(HafaTheme.accent)
                        .foregroundStyle(HafaTheme.canvas)
                        .accessibilityIdentifier("addTVButton")
                        .disabled(restoration.isRestoring)

                        Spacer(minLength: 24)
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    .padding(.horizontal, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .navigationTitle("Hafa Remote")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !savedTVs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    myTVsButton
                }
            }
        }
    }

    private var restoringState: some View {
        let presentation = SavedTVRestorationPresentation(state: session.state)

        return ZStack {
            HafaTheme.canvas
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(HafaTheme.accent)

                Text(presentation.title)
                    .font(.headline)
                    .foregroundStyle(.white)

                if let instruction = presentation.instruction {
                    Text(instruction)
                        .font(.body)
                        .foregroundStyle(HafaTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }

                if let savedTV = savedTVs.first {
                    Text(savedTV.displayName)
                        .font(.subheadline)
                        .foregroundStyle(HafaTheme.secondaryText)
                }
            }
            .padding(24)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("restoringSavedTVState")
        }
        .navigationTitle("Hafa Remote")
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var statusLabel: String {
        if selection.isSwitching { return "Connecting" }
        return switch session.state {
        case .connected:
            isPresentedTVConnected ? "Connected" : "Offline"
        case .pairing:
            "Pairing"
        case .connecting:
            "Connecting"
        case .reconnecting(let attempt):
            "Reconnecting (attempt \(attempt))"
        case .offline:
            "Offline"
        case .denied:
            "Approval denied"
        case .savedPairingRejected:
            "Pairing expired"
        case .certificateChanged:
            "Pairing changed"
        case .unsupported:
            "Unsupported"
        case .failed:
            "Connection issue"
        case .idle:
            "Disconnected"
        }
    }

    private func restoreLastUsedTVIfNeeded() async {
        if selection.selectedDeviceKey == nil {
            selection.selectWithoutConnecting(savedTVs.first?.stableDeviceKey)
        }
        await restoration.restore(
            from: savedTVs,
            skipBecauseConnectionWasInitiated: session.hasInitiatedConnection
        ) { target in
            await session.connect(to: target)
        }
    }

    private var selectedSavedTV: SavedTV? {
        guard let selectedDeviceKey = selection.selectedDeviceKey else { return nil }
        return savedTVs.first(where: { $0.stableDeviceKey == selectedDeviceKey })
    }

    private var presentedTV: ConnectedTV? {
        if let selectedSavedTV {
            if session.connectedTV?.stableDeviceKey == selectedSavedTV.stableDeviceKey {
                return session.connectedTV
            }
            return selectedSavedTV.rememberedTV
        }
        return session.lastConnectedTV
    }

    private var isPresentedTVConnected: Bool {
        guard let presentedTV else { return false }
        return session.connectedTV?.stableDeviceKey == presentedTV.stableDeviceKey
    }

    private var myTVsButton: some View {
        Button("My TVs") {
            isShowingMyTVs = true
        }
        .accessibilityHint("Shows saved TVs, rooms, editing, and Add TV")
        .accessibilityIdentifier("myTVsButton")
    }

    private func select(_ savedTV: SavedTV) {
        guard let target = savedTV.connectionTarget else {
            alert = HomeAlert(
                title: "Can't Connect",
                message:
                    "Hafa Remote no longer has a valid network address for \(savedTV.displayName). Add it again while the TV is on."
            )
            return
        }
        guard savedTV.stableDeviceKey != selection.selectedDeviceKey || !isPresentedTVConnected
        else { return }

        selection.select(
            deviceKey: savedTV.stableDeviceKey,
            target: target,
            disconnect: {
                await session.disconnect(clearRememberedTV: false)
            },
            connect: { target in
                await session.connect(to: target)
            }
        )
    }

    /// Removes a saved TV while disrupting the active session only when that TV owns it.
    private func forget(_ savedTV: SavedTV) async throws {
        let removedKey = savedTV.stableDeviceKey
        let remainingTVs = savedTVs.filter { $0.stableDeviceKey != removedKey }
        let selectedBeforeRemoval = selectedSavedTV
        let affectsActiveSession =
            selectedBeforeRemoval?.stableDeviceKey == removedKey
            || session.connectedTV?.stableDeviceKey == removedKey
        let reconnectTV =
            affectsActiveSession
            ? remainingTVs.first(where: { $0.connectionTarget != nil }) : selectedBeforeRemoval
        let replacementDeviceKey = reconnectTV?.stableDeviceKey
        let reconnectTarget = reconnectTV?.connectionTarget
        let recoverySnapshot = SavedTVRecoverySnapshot(savedTV)

        modelContext.delete(savedTV)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        do {
            try await session.removePairingCredential(
                for: recoverySnapshot.lastKnownAddress,
                reportedDeviceID: recoverySnapshot.reportedDeviceID,
                brand: recoverySnapshot.brand
            )
        } catch {
            modelContext.insert(recoverySnapshot.makeSavedTV())
            do {
                try modelContext.save()
            } catch {
                throw SavedTVRemovalError.couldNotRestoreMetadata
            }
            throw error
        }

        if affectsActiveSession {
            await session.disconnect()
        }
        selection.removeSelection(
            for: removedKey,
            replacementDeviceKey: replacementDeviceKey
        )
        if affectsActiveSession, let target = reconnectTarget {
            await session.connect(to: target)
        }
    }

    private func displayName(for tv: ConnectedTV) -> String {
        savedTV(for: tv)?.displayName ?? tv.brand.defaultDeviceName
    }

    private func savedTV(for tv: ConnectedTV) -> SavedTV? {
        savedTVs.first(where: { $0.stableDeviceKey == tv.stableDeviceKey })
    }

    private func wakeMACAddress(
        for tv: ConnectedTV,
        savedTV: SavedTV?
    ) -> TVMACAddress? {
        guard tv.isEligibleForSamsungWake else { return nil }
        return tv.macAddress ?? savedTV?.validatedMACAddress
    }

    private func canPowerOn(_ tv: ConnectedTV, savedTV: SavedTV?) -> Bool {
        switch tv.brand {
        case .samsung:
            wakeMACAddress(for: tv, savedTV: savedTV) != nil
        case .sony, .vizio:
            savedTV?.connectionTarget != nil
        }
    }

    private func powerOnHelpText(for brand: TVBrand) -> String {
        switch brand {
        case .samsung:
            "Requires Power On With Mobile in the Samsung TV's Network settings."
        case .sony:
            "Requires Remote Start or network standby in the Sony TV's settings."
        case .vizio:
            "Requires Quick Start mode in the Vizio TV's System settings."
        }
    }

    private func powerOnFailureText(for brand: TVBrand) -> String {
        "The \(brand.displayName) TV did not respond. Confirm the iPhone and TV use the same Wi-Fi, enable \(powerOnSettingName(for: brand)), then try again."
    }

    /// Describes an undelivered power-off action without guessing which layer rejected it.
    private func powerOffFailureText(for brand: TVBrand) -> String {
        "Hafa Remote could not deliver power off to the \(brand.displayName) TV. Confirm it is still connected, then try again."
    }

    private func powerOnSettingName(for brand: TVBrand) -> String {
        switch brand {
        case .samsung:
            "Power On With Mobile"
        case .sony:
            "Remote Start or network standby"
        case .vizio:
            "Quick Start mode"
        }
    }

    private func powerOn(_ tv: ConnectedTV, savedTV: SavedTV?) async throws {
        switch tv.brand {
        case .samsung:
            try await wake(tv, savedTV: savedTV)
        case .sony, .vizio:
            guard let target = savedTV?.connectionTarget else {
                throw TVSelectionError.notConnected
            }
            _ = try await session.connectAndWait(to: target, timeout: .seconds(30))
            try await session.send(.powerOn)
        }
    }

    private func wake(_ tv: ConnectedTV, savedTV: SavedTV?) async throws {
        guard let macAddress = wakeMACAddress(for: tv, savedTV: savedTV) else {
            throw TVMACAddressError.invalid
        }

        let attempt = PendingWakeAttempt(stableDeviceKey: tv.stableDeviceKey)
        pendingWakeAttempt = attempt
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard pendingWakeAttempt?.id == attempt.id else { return }
            pendingWakeAttempt = nil
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await wakeService.wake(macAddress, at: tv.address)
                    try await Task.sleep(for: .seconds(2))
                    _ = try await session.connectAndWait(
                        to: tv.address.rawValue,
                        timeout: .seconds(30)
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw RemoteSessionControllerError.timedOut(.connect)
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            if pendingWakeAttempt?.id == attempt.id {
                pendingWakeAttempt = nil
            }
            throw error
        }
    }

    private func saveConnectedTV(_ tv: ConnectedTV) {
        selection.markConnected(tv.stableDeviceKey)
        let now = Date.now
        let wakeWasJustVerified = pendingWakeAttempt?.matches(tv) == true
        if let saved = savedTVs.first(where: { $0.stableDeviceKey == tv.stableDeviceKey }) {
            saved.recordConnection(
                to: tv,
                at: now,
                wakeWasJustVerified: wakeWasJustVerified
            )
        } else {
            let canPersistWakeMetadata = tv.networkConnection == .wireless
            modelContext.insert(
                SavedTV(
                    brand: tv.brand,
                    reportedDeviceID: tv.reportedDeviceID,
                    displayName: tv.displayName ?? tv.brand.defaultDeviceName,
                    modelName: tv.modelName,
                    firmwareVersion: tv.firmwareVersion,
                    lastKnownAddress: tv.address.rawValue,
                    controlPort: tv.controlPort,
                    macAddress: canPersistWakeMetadata ? tv.macAddress?.persistedValue : nil,
                    wakeWasVerified: canPersistWakeMetadata && wakeWasJustVerified,
                    lastSeenAt: now,
                    lastUsedAt: now
                )
            )
        }

        if wakeWasJustVerified {
            pendingWakeAttempt = nil
        }

        do {
            try modelContext.save()
        } catch {
            alert = HomeAlert(
                title: "TV Not Saved",
                message:
                    "The TV is connected, but Hafa Remote could not remember it for the next launch."
            )
        }
    }

    private func backfillLegacySavedTVsIfNeeded() {
        let recordsNeedingBackfill = savedTVs.filter { $0.stableDeviceID == nil }
        guard !recordsNeedingBackfill.isEmpty else { return }
        SavedTVLegacyIdentityMigration.apply(to: savedTVs, in: modelContext)
        do {
            try modelContext.save()
        } catch {
            alert = HomeAlert(
                title: "TV Not Saved",
                message:
                    "Hafa Remote could not finish updating a saved TV. Reconnect it to keep it available."
            )
        }
    }
}

private enum SavedTVRemovalError: Error {
    case couldNotRestoreMetadata
}

struct SavedTVRecoverySnapshot {
    let id: UUID
    let stableDeviceID: String?
    let brand: TVBrand
    let reportedDeviceID: String
    let displayName: String
    let roomName: String?
    let modelName: String
    let firmwareVersion: String?
    let lastKnownAddress: String
    let controlPort: Int?
    let macAddress: String?
    let wakeWasVerified: Bool
    let lastSeenAt: Date
    let lastUsedAt: Date

    /// Captures every persisted field before the record is removed from SwiftData.
    init(_ savedTV: SavedTV) {
        id = savedTV.id
        stableDeviceID = savedTV.stableDeviceID
        brand = savedTV.brand
        reportedDeviceID = savedTV.reportedDeviceID
        displayName = savedTV.displayName
        roomName = savedTV.roomName
        modelName = savedTV.modelName
        firmwareVersion = savedTV.firmwareVersion
        lastKnownAddress = savedTV.lastKnownAddress
        controlPort = savedTV.controlPort
        macAddress = savedTV.macAddress
        wakeWasVerified = savedTV.wakeWasVerified
        lastSeenAt = savedTV.lastSeenAt
        lastUsedAt = savedTV.lastUsedAt
    }

    /// Recreates the exact local metadata if credential deletion fails.
    func makeSavedTV() -> SavedTV {
        let savedTV = SavedTV(
            id: id,
            brand: brand,
            reportedDeviceID: reportedDeviceID,
            displayName: displayName,
            roomName: roomName,
            modelName: modelName,
            firmwareVersion: firmwareVersion,
            lastKnownAddress: lastKnownAddress,
            macAddress: macAddress,
            wakeWasVerified: wakeWasVerified,
            lastSeenAt: lastSeenAt,
            lastUsedAt: lastUsedAt
        )
        savedTV.stableDeviceID = stableDeviceID
        savedTV.controlPort = controlPort
        return savedTV
    }
}

private struct MyTVsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let savedTVs: [SavedTV]
    let selectedDeviceKey: String?
    let connectedDeviceKey: String?
    let isSwitching: Bool
    let selectTV: @MainActor (SavedTV) -> Void
    let addTV: @MainActor () -> Void
    let forgetTV: @MainActor (SavedTV) async throws -> Void

    @State private var editRequest: SavedTVEditRequest?
    @State private var activeAlert: MyTVsAlert?
    @State private var forgettingDeviceKey: String?

    /// Builds a local, account-free library for every previously paired TV.
    var body: some View {
        NavigationStack {
            ZStack {
                HafaTheme.canvas
                    .ignoresSafeArea()

                List {
                    Section {
                        ForEach(savedTVs, id: \.stableDeviceKey) { savedTV in
                            savedTVRow(savedTV)
                        }
                    } header: {
                        Text("Saved TVs")
                    } footer: {
                        Text(
                            "Saved only on this iPhone. Pairing credentials stay protected in Keychain."
                        )
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("My TVs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    addTV()
                } label: {
                    Label("Add TV", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(HafaTheme.accent)
                .foregroundStyle(HafaTheme.canvas)
                .accessibilityIdentifier("addTVFromLibraryButton")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $editRequest) { request in
            SavedTVEditor(savedTV: request.savedTV) { displayName, roomName in
                try saveEdits(
                    for: request.savedTV,
                    displayName: displayName,
                    roomName: roomName
                )
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert.kind {
            case .confirmForget(let savedTV):
                Alert(
                    title: Text("Forget \(savedTV.displayName)?"),
                    message: Text(
                        "This removes the saved TV and its pairing credential from this iPhone."
                    ),
                    primaryButton: .destructive(Text("Forget")) {
                        forget(savedTV)
                    },
                    secondaryButton: .cancel()
                )
            case .error(let message):
                Alert(
                    title: Text("Couldn’t Update My TVs"),
                    message: Text(message),
                    dismissButton: .cancel(Text("OK"))
                )
            }
        }
    }

    /// Builds one selectable TV row with visible state and secondary management actions.
    private func savedTVRow(_ savedTV: SavedTV) -> some View {
        let isSelected = savedTV.stableDeviceKey == selectedDeviceKey
        let isConnected = savedTV.stableDeviceKey == connectedDeviceKey
        let isForgetting = savedTV.stableDeviceKey == forgettingDeviceKey

        return HStack(spacing: 12) {
            Button {
                selectTV(savedTV)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tv")
                        .font(.title3)
                        .foregroundStyle(HafaTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(HafaTheme.accent.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(savedTV.displayName)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(savedTVDetail(savedTV))
                            .font(.caption2)
                            .foregroundStyle(HafaTheme.secondaryText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    if isForgetting {
                        ProgressView()
                            .tint(HafaTheme.accent)
                    } else if isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(HafaTheme.accent)
                            .accessibilityLabel("Connected")
                    } else if isSelected && isSwitching {
                        ProgressView()
                            .tint(HafaTheme.accent)
                            .accessibilityLabel("Connecting")
                    } else if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(HafaTheme.accent)
                            .accessibilityLabel("Selected")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .disabled(isForgetting)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("myTVRow-\(savedTV.stableDeviceKey)")

            Menu {
                Button("Edit Name & Room", systemImage: "pencil") {
                    editRequest = SavedTVEditRequest(savedTV: savedTV)
                }
                .accessibilityIdentifier("editMyTV-\(savedTV.stableDeviceKey)")

                Button("Forget TV", systemImage: "trash", role: .destructive) {
                    activeAlert = MyTVsAlert(kind: .confirmForget(savedTV))
                }
                .accessibilityIdentifier("forgetMyTV-\(savedTV.stableDeviceKey)")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isForgetting)
            .accessibilityLabel("Manage \(savedTV.displayName)")
            .accessibilityIdentifier("manageMyTV-\(savedTV.stableDeviceKey)")
        }
        .listRowBackground(HafaTheme.surface)
    }

    /// Combines optional room context with stable brand and model details.
    private func savedTVDetail(_ savedTV: SavedTV) -> String {
        let device = "\(savedTV.brand.displayName) · \(savedTV.modelName)"
        guard let roomName = savedTV.roomName, !roomName.isEmpty else { return device }
        return "\(roomName) · \(device)"
    }

    /// Persists user-facing labels while restoring the prior values if storage fails.
    private func saveEdits(
        for savedTV: SavedTV,
        displayName: String,
        roomName: String?
    ) throws {
        let previousDisplayName = savedTV.displayName
        let previousRoomName = savedTV.roomName
        savedTV.displayName = displayName
        savedTV.roomName = roomName
        do {
            try modelContext.save()
        } catch {
            savedTV.displayName = previousDisplayName
            savedTV.roomName = previousRoomName
            throw error
        }
    }

    /// Removes one TV and keeps the sheet responsive during credential deletion.
    private func forget(_ savedTV: SavedTV) {
        guard forgettingDeviceKey == nil else { return }
        let deviceKey = savedTV.stableDeviceKey
        forgettingDeviceKey = deviceKey
        Task { @MainActor in
            defer {
                if forgettingDeviceKey == deviceKey {
                    forgettingDeviceKey = nil
                }
            }
            do {
                try await forgetTV(savedTV)
            } catch is CancellationError {
                return
            } catch {
                activeAlert = MyTVsAlert(
                    kind: .error(
                        "The TV or its saved pairing could not be removed from this iPhone. Try again."
                    )
                )
            }
        }
    }
}

private struct SavedTVEditRequest: Identifiable {
    let id = UUID()
    let savedTV: SavedTV
}

private struct MyTVsAlert: Identifiable {
    enum Kind {
        case confirmForget(SavedTV)
        case error(String)
    }

    let id = UUID()
    let kind: Kind
}

private struct SavedTVEditor: View {
    @Environment(\.dismiss) private var dismiss

    let savedTV: SavedTV
    let save: @MainActor (String, String?) throws -> Void

    @State private var displayName: String
    @State private var roomName: String
    @State private var errorMessage: String?

    /// Starts the editor with the TV's current local labels.
    init(
        savedTV: SavedTV,
        save: @escaping @MainActor (String, String?) throws -> Void
    ) {
        self.savedTV = savedTV
        self.save = save
        _displayName = State(initialValue: savedTV.displayName)
        _roomName = State(initialValue: savedTV.roomName ?? "")
    }

    private var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedRoomName: String? {
        let roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        return roomName.isEmpty ? nil : roomName
    }

    private var canSave: Bool {
        !normalizedDisplayName.isEmpty
            && normalizedDisplayName.count <= 80
            && (normalizedRoomName?.count ?? 0) <= 40
            && !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !roomName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// Builds a short, native edit form with no account or network dependency.
    var body: some View {
        NavigationStack {
            Form {
                Section("TV Name") {
                    TextField("Living Room TV", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("savedTVNameField")
                    Text("\(displayName.count)/80")
                        .font(.caption)
                        .foregroundStyle(HafaTheme.secondaryText)
                }

                Section("Room (Optional)") {
                    TextField("Living Room", text: $roomName)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("savedTVRoomField")
                    Text("\(roomName.count)/40")
                        .font(.caption)
                        .foregroundStyle(HafaTheme.secondaryText)
                }

                Section("Device") {
                    LabeledContent("Brand", value: savedTV.brand.displayName)
                    LabeledContent("Model", value: savedTV.modelName)
                }
            }
            .navigationTitle("Edit TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEdits()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("saveTVEditsButton")
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert(
            "Couldn’t Save TV",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Validates and persists the local display metadata before dismissing.
    private func saveEdits() {
        guard canSave else { return }
        do {
            try save(normalizedDisplayName, normalizedRoomName)
            dismiss()
        } catch {
            errorMessage = "Hafa Remote could not save these changes. Try again."
        }
    }
}

private struct HomeAlert {
    let title: String
    let message: String
}

enum TVSelectionError: Error {
    case notConnected
}

@MainActor
@Observable
final class SavedTVSelectionCoordinator {
    private(set) var selectedDeviceKey: String?
    private(set) var isSwitching = false
    private var operationID: UUID?
    private nonisolated let taskHolder = SavedTVSelectionTaskHolder()

    func selectWithoutConnecting(_ deviceKey: String?) {
        guard selectedDeviceKey == nil else { return }
        selectedDeviceKey = deviceKey
    }

    func markConnected(_ deviceKey: String) {
        selectedDeviceKey = deviceKey
        isSwitching = false
        operationID = nil
        taskHolder.cancel()
    }

    /// Clears a removed selection and optionally promotes a remaining saved TV.
    func removeSelection(for deviceKey: String, replacementDeviceKey: String?) {
        guard selectedDeviceKey == deviceKey else { return }
        taskHolder.cancel()
        selectedDeviceKey = replacementDeviceKey
        isSwitching = false
        operationID = nil
    }

    func select(
        deviceKey: String,
        target: TVConnectionTarget,
        disconnect: @escaping @MainActor () async -> Void,
        connect: @escaping @MainActor (TVConnectionTarget) async -> Void
    ) {
        taskHolder.cancel()
        let operationID = UUID()
        self.operationID = operationID
        selectedDeviceKey = deviceKey
        isSwitching = true
        taskHolder.install(
            Task { @MainActor [weak self] in
                await disconnect()
                guard !Task.isCancelled, self?.operationID == operationID else { return }
                await connect(target)
                guard !Task.isCancelled, self?.operationID == operationID else { return }
                self?.isSwitching = false
                self?.operationID = nil
            })
    }
}

private final class SavedTVSelectionTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    deinit {
        cancel()
    }
}

struct PendingWakeAttempt: Equatable {
    let id = UUID()
    let stableDeviceKey: String

    func matches(_ tv: ConnectedTV) -> Bool {
        stableDeviceKey == tv.stableDeviceKey
    }
}

struct SavedTVRestorationPresentation: Equatable {
    let title: String
    let instruction: String?

    init(state: RemoteSessionState) {
        if case .pairing = state {
            title = "Approve Hafa Remote on your TV"
            instruction = "Follow the approval prompt on your TV to finish connecting."
        } else {
            title = "Connecting to your TV…"
            instruction = nil
        }
    }
}

@MainActor
@Observable
final class SavedTVRestorationCoordinator {
    private(set) var isRestoring = false
    private var didAttempt = false

    func restore(
        from savedTVs: [SavedTV],
        skipBecauseConnectionWasInitiated: Bool = false,
        connect: @MainActor (TVConnectionTarget) async throws -> Void
    ) async {
        guard !didAttempt else { return }
        if skipBecauseConnectionWasInitiated {
            didAttempt = true
            return
        }
        guard let target = savedTVs.first?.connectionTarget else { return }
        didAttempt = true

        isRestoring = true
        defer { isRestoring = false }
        try? await connect(target)
    }
}

private struct ScenePhaseEvents {
    let stream: AsyncStream<ScenePhase>
    let continuation: AsyncStream<ScenePhase>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }
}

#Preview {
    HomeView()
        .modelContainer(for: SavedTV.self, inMemory: true)
}
