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
    @State private var scenePhaseEvents = ScenePhaseEvents()
    @State private var restoration = SavedTVRestorationCoordinator()
    @State private var selection = SavedTVSelectionCoordinator()
    @State private var persistenceWarning: String?
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
                    canWakeTV: wakeMACAddress(for: tv, savedTV: savedTV) != nil,
                    wakeWasVerified: savedTV?.wakeWasVerified ?? false
                ) { command in
                    guard isPresentedTVConnected else { return }
                    try? await session.send(command)
                } textAction: { input in
                    guard isPresentedTVConnected else {
                        throw TVSelectionError.notConnected
                    }
                    try await session.sendText(input)
                } wakeAction: {
                    try await wake(tv, savedTV: savedTV)
                } retry: {
                    await session.connect(to: tv.connectionTarget)
                } showTVSetup: {
                    isShowingSetup = true
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        tvPicker
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
        .alert(
            "TV Not Saved",
            isPresented: Binding(
                get: { persistenceWarning != nil },
                set: { if !$0 { persistenceWarning = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(persistenceWarning ?? "")
        }
        .task(id: savedTVs.first?.persistentModelID) {
            backfillLegacySavedTVsIfNeeded()
            await restoreLastUsedTVIfNeeded()
        }
        .onChange(of: session.state) { _, state in
            guard case .connected(let tv) = state else { return }
            selection.markConnected(tv.stableDeviceKey)
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
        guard isPresentedTVConnected else {
            if selection.isSwitching { return "Connecting" }
            return "Offline"
        }
        return switch session.state {
        case .connected:
            "Connected"
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
        await restoration.restore(from: savedTVs) { target in
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

    @ViewBuilder
    private var tvPicker: some View {
        Menu {
            ForEach(savedTVs, id: \.stableDeviceKey) { savedTV in
                Button {
                    select(savedTV)
                } label: {
                    if savedTV.stableDeviceKey == selection.selectedDeviceKey {
                        Label(savedTV.displayName, systemImage: "checkmark")
                    } else {
                        Text(savedTV.displayName)
                    }
                }
                .accessibilityIdentifier("savedTV-\(savedTV.stableDeviceKey)")
            }

            if !savedTVs.isEmpty {
                Divider()
            }

            Button("Add TV", systemImage: "plus") {
                isShowingSetup = true
            }
            .accessibilityIdentifier("addAnotherTVButton")
        } label: {
            Label("TVs", systemImage: "tv.badge.wifi")
        }
        .accessibilityIdentifier("changeTVButton")
    }

    private func select(_ savedTV: SavedTV) {
        guard let target = savedTV.connectionTarget else {
            persistenceWarning =
                "Hafa Remote no longer has a valid network address for \(savedTV.displayName). Add it again while the TV is on."
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
                    displayName: tv.brand.defaultDeviceName,
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
            persistenceWarning =
                "The TV is connected, but Hafa Remote could not remember it for the next launch."
        }
    }

    private func backfillLegacySavedTVsIfNeeded() {
        let recordsNeedingBackfill = savedTVs.filter { $0.stableDeviceID == nil }
        guard !recordsNeedingBackfill.isEmpty else { return }
        SavedTVLegacyIdentityMigration.apply(to: savedTVs, in: modelContext)
        do {
            try modelContext.save()
        } catch {
            persistenceWarning =
                "Hafa Remote could not finish updating a saved TV. Reconnect it to keep it available."
        }
    }
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
        connect: @MainActor (TVConnectionTarget) async throws -> Void
    ) async {
        guard !didAttempt else { return }
        didAttempt = true
        guard let target = savedTVs.first?.connectionTarget else { return }

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
