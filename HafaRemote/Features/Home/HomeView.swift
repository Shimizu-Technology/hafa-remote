import SwiftData
import SwiftUI

/// Owns the user-facing flow from first launch through active remote control.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \SavedTV.lastUsedAt, order: .reverse) private var savedTVs: [SavedTV]
    @State private var session: RemoteSessionStore
    @State private var networkMonitor = LocalNetworkMonitor()
    @State private var isShowingSetup = false
    @State private var scenePhaseEvents = ScenePhaseEvents()
    @State private var restoration = SavedTVRestorationCoordinator()
    @State private var persistenceWarning: String?

    init(session: RemoteSessionStore = RemoteSessionStore()) {
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            if let tv = session.lastConnectedTV {
                RemoteControlView(
                    tvName: displayName(for: tv),
                    modelName: tv.modelName,
                    statusLabel: statusLabel,
                    isConnected: session.canSendCommands
                ) { command in
                    try? await session.send(command)
                } textAction: { input in
                    try await session.sendText(input)
                } retry: {
                    await session.connect(to: tv.address.rawValue)
                } showTVSetup: {
                    isShowingSetup = true
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Change TV", systemImage: "tv.badge.wifi") {
                            Task {
                                await session.disconnect(clearRememberedTV: false)
                                isShowingSetup = true
                            }
                        }
                        .accessibilityIdentifier("changeTVButton")
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
            SamsungSetupView(
                session: session,
                initialAddress:
                    session.lastConnectedTV?.address.rawValue
                    ?? savedTVs.first?.lastKnownAddress
                    ?? ""
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
                                "Connect a Samsung TV on this Wi-Fi network. No account, ads, or subscription."
                            )
                            .font(.body)
                            .foregroundStyle(HafaTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        }

                        Button {
                            isShowingSetup = true
                        } label: {
                            Label("Add Samsung TV", systemImage: "plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(HafaTheme.accent)
                        .foregroundStyle(HafaTheme.canvas)
                        .accessibilityIdentifier("addSamsungTVButton")
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
        switch session.state {
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
        await restoration.restore(from: savedTVs) { address in
            await session.connect(to: address.rawValue)
        }
    }

    private func displayName(for tv: PairedSamsungTV) -> String {
        savedTVs.first(where: { $0.reportedDeviceID == tv.reportedDeviceID })?.displayName
            ?? "Samsung TV"
    }

    private func saveConnectedTV(_ tv: PairedSamsungTV) {
        let now = Date.now
        if let saved = savedTVs.first(where: { $0.reportedDeviceID == tv.reportedDeviceID }) {
            saved.recordConnection(to: tv, at: now)
        } else {
            modelContext.insert(
                SavedTV(
                    reportedDeviceID: tv.reportedDeviceID,
                    displayName: "Samsung TV",
                    modelName: tv.modelName,
                    firmwareVersion: tv.firmwareVersion,
                    lastKnownAddress: tv.address.rawValue,
                    lastSeenAt: now,
                    lastUsedAt: now
                )
            )
        }

        do {
            try modelContext.save()
        } catch {
            persistenceWarning =
                "The TV is connected, but Hafa Remote could not remember it for the next launch."
        }
    }
}

struct SavedTVRestorationPresentation: Equatable {
    let title: String
    let instruction: String?

    init(state: RemoteSessionState) {
        if case .pairing = state {
            title = "Approve Hafa Remote on your TV"
            instruction = "Choose Allow on the Samsung TV to finish connecting."
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
        connect: @MainActor (PrivateIPv4Address) async throws -> Void
    ) async {
        guard !didAttempt else { return }
        didAttempt = true
        guard let address = savedTVs.first?.validatedAddress else { return }

        isRestoring = true
        defer { isRestoring = false }
        try? await connect(address)
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
