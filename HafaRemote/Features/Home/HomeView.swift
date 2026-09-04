import SwiftUI

/// Owns the user-facing flow from first launch through active remote control.
struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: RemoteSessionStore
    @State private var isShowingSetup = false

    init(session: RemoteSessionStore = RemoteSessionStore()) {
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            if let tv = session.lastConnectedTV {
                RemoteControlView(
                    tvName: "Samsung TV",
                    modelName: tv.modelName,
                    statusLabel: statusLabel,
                    isConnected: session.canSendCommands
                ) { command in
                    try? await session.send(command)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Change TV", systemImage: "tv.badge.wifi") {
                            isShowingSetup = true
                        }
                        .accessibilityIdentifier("changeTVButton")
                    }
                }
            } else {
                emptyState
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSetup) {
            SamsungSetupView(session: session)
        }
        .onChange(of: scenePhase) { _, phase in
            Task { @MainActor in
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

    private var statusLabel: String {
        switch session.state {
        case .connected:
            "Connected"
        case .pairing:
            "Pairing"
        case .connecting:
            "Connecting"
        case .reconnecting(let attempt):
            "Reconnecting \(attempt)"
        case .offline:
            "Offline"
        case .denied:
            "Approval denied"
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
}

#Preview {
    HomeView()
}
