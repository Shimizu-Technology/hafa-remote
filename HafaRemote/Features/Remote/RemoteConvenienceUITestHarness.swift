#if DEBUG && !HAFA_PUBLIC_BUILD
    import Observation
    import SwiftUI

    /// Native acceptance fixture: real store/controller/views, no network or Keychain implementation.
    struct RemoteConvenienceUITestHarness: View {
        @State private var probe: ConvenienceUIProbe
        @State private var session: RemoteSessionStore
        @State private var showsConveniences = ProcessInfo.processInfo.arguments.contains(
            "-convenience-start-more")
        private let preferences: TVConveniencePreferences
        private let brand: TVBrand
        private let negotiated: Bool
        @State private var selectedIdentity = "synthetic-ui-a"

        init() {
            let arguments = ProcessInfo.processInfo.arguments
            let brand: TVBrand =
                arguments.contains("-convenience-vizio")
                ? .vizio
                : arguments.contains("-convenience-sony") ? .sony : .samsung
            self.brand = brand
            negotiated = !arguments.contains("-convenience-no-optional-features")
            let probe = ConvenienceUIProbe()
            let television = ConvenienceUIFixtureDriver.television(
                brand: brand, identity: "synthetic-ui-a", negotiated: negotiated)
            let driver = ConvenienceUIFixtureDriver(
                brand: brand, negotiated: negotiated, television: television, probe: probe)
            _probe = State(initialValue: probe)
            _session = State(
                initialValue: RemoteSessionStore(
                    controller: RemoteSessionController(driver: driver, initialState: .connected(television)),
                    initialState: .connected(television)))
            let suite = "com.shimizutechnology.hafaremote.synthetic-convenience-ui"
            guard let defaults = UserDefaults(suiteName: suite) else {
                preconditionFailure("Synthetic suite unavailable")
            }
            // This one explicitly disposable DEBUG fixture domain never touches production defaults.
            defaults.removePersistentDomain(forName: suite)
            preferences = TVConveniencePreferences(defaults: defaults)
            if brand == .vizio, arguments.contains("-convenience-restored-favorite") {
                let favorite = try! TVAppShortcut(
                    name: "Synthetic Saved Video", target: .vizio(appID: "synthetic-video", namespace: 3))
                try! preferences.toggleFavorite(favorite, for: television.stableDeviceKey)
            }
        }

        var body: some View {
            NavigationStack {
                if let television = session.connectedTV {
                    RemoteControlView(
                        tvName:
                            "Synthetic \(brand.displayName) \(television.reportedDeviceID == "synthetic-ui-a" ? "A" : "B")",
                        modelName: "Offline acceptance fixture", statusLabel: "Connected — simulated",
                        isConnected: true, powerState: .on, isReconnecting: false, isAwaitingApproval: false,
                        capabilities: television.capabilities, canPowerOnTV: false, powerOnWasVerified: false,
                        powerOnHelpText: "Simulated only", powerOnFailureText: "Simulated only",
                        powerOffFailureText: "Simulated only",
                        convenienceContext: RemoteConvenienceContext(
                            stableDeviceKey: television.stableDeviceKey, brand: brand,
                            preferences: preferences
                        ) { request in
                            try await session.convenience(
                                request, expectedDeviceKey: television.stableDeviceKey)
                        },
                        action: { command in
                            try? await session.send(command, expectedDeviceKey: television.stableDeviceKey)
                        },
                        textAction: { input in
                            try await session.sendText(input, expectedDeviceKey: television.stableDeviceKey)
                        }, powerOnAction: {}, powerOffAction: {}, retry: {}, showTVSetup: {}
                    )
                    .id(television.stableDeviceKey)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Switch Fixture TV") {
                                selectedIdentity =
                                    selectedIdentity == "synthetic-ui-a" ? "synthetic-ui-b" : "synthetic-ui-a"
                                let target = ConvenienceUIFixtureDriver.television(
                                    brand: brand, identity: selectedIdentity, negotiated: negotiated
                                ).connectionTarget
                                Task { await session.connect(to: target) }
                            }
                            .accessibilityIdentifier("switchConvenienceFixtureTV")
                        }
                    }
                    .navigationDestination(isPresented: $showsConveniences) {
                        RemoteConveniencesView(
                            context: RemoteConvenienceContext(
                                stableDeviceKey: television.stableDeviceKey, brand: brand,
                                preferences: preferences
                            ) { request in
                                try await session.convenience(
                                    request, expectedDeviceKey: television.stableDeviceKey)
                            }, capabilities: television.capabilities, isConnected: true
                        ) { command in
                            try? await session.send(command, expectedDeviceKey: television.stableDeviceKey)
                        }
                    }
                } else {
                    ProgressView("Switching synthetic TV…")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !ProcessInfo.processInfo.arguments.contains("-convenience-visible-trace") {
                    Text(probe.lastEvent).font(.caption2).opacity(0.01)
                        .accessibilityIdentifier("convenienceFixtureTrace")
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if ProcessInfo.processInfo.arguments.contains("-convenience-visible-trace") {
                    // An opaque, bounded DEBUG witness stays in the AX tree without covering controls.
                    Text(probe.lastEvent)
                        .font(.caption2.monospaced())
                        .dynamicTypeSize(.large)
                        .foregroundStyle(HafaTheme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(HafaTheme.canvas)
                        .accessibilityIdentifier("convenienceFixtureTrace")
                        .allowsHitTesting(false)
                }
            }
            .preferredColorScheme(
                ProcessInfo.processInfo.arguments.contains("-convenience-dark") ? .dark : .light)
        }
    }

    @MainActor @Observable final class ConvenienceUIProbe {
        var lastEvent = "none"
    }

    actor ConvenienceUIFixtureDriver: RemoteSessionDriving {
        nonisolated let brand: TVBrand
        let negotiated: Bool
        let probe: ConvenienceUIProbe
        private var television: ConnectedTV
        init(brand: TVBrand, negotiated: Bool, television: ConnectedTV, probe: ConvenienceUIProbe) {
            self.brand = brand
            self.negotiated = negotiated
            self.television = television
            self.probe = probe
        }
        nonisolated static func television(brand: TVBrand, identity: String, negotiated: Bool) -> ConnectedTV
        {
            var capabilities = TVCapability.implemented(for: brand)
            if !negotiated {
                capabilities.subtract([.favoriteApps, .textInput, .guide, .numberPad, .inputSelection])
            }
            guard let address = try? PrivateIPv4Address(documentationAddressForTesting: "192.0.2.45") else {
                preconditionFailure("Synthetic documentation address invalid")
            }
            return ConnectedTV(
                brand: brand, reportedDeviceID: identity, address: address,
                controlPort: brand == .samsung ? 8002 : brand == .sony ? 6466 : 7345,
                modelName: "Synthetic Model", firmwareVersion: "1.0", capabilities: capabilities,
                powerState: .on)
        }
        func connect(
            addressText: String, onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) throws -> ConnectedTV { throw TVConvenienceError.unavailable }
        func connect(
            to target: TVConnectionTarget,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) -> ConnectedTV {
            television = Self.television(
                brand: brand, identity: target.expectedSavedDeviceID ?? target.reportedDeviceID,
                negotiated: negotiated)
            return television
        }
        func send(_ command: RemoteCommand) async {
            await record("command:\(command.rawValue)")
        }
        func sendText(_ input: RemoteTextInput) async throws {
            await record("text:characters:\(input.value.count)")
            if brand == .sony { throw TVConvenienceError.textFieldNotFocused }
        }
        func convenience(_ request: TVConvenienceRequest) async throws -> TVConvenienceResponse {
            switch request {
            case .apps:
                await record("request:apps")
                guard negotiated else { throw TVConvenienceError.unavailable }
                if brand == .sony { return .apps(TVAppShortcut.sonyConfiguredLinks) }
                return .apps([
                    try TVAppShortcut(
                        name: "Synthetic Video", target: .samsung(appID: "synthetic-video", deepLink: true)),
                    try TVAppShortcut(
                        name: "Synthetic Music", target: .samsung(appID: "synthetic-music", deepLink: false)),
                ])
            case .inputs:
                await record("request:inputs")
                return .inputs([
                    try TVInputSource(value: "HDMI-1", name: "Synthetic Console"),
                    try TVInputSource(value: "HDMI-2", name: "Synthetic Player"),
                ])
            case .selectInput(let input):
                await record("request:input:\(input.value)")
                return .sent
            case .launch(let app):
                await record("request:launch:\(app.name)")
                return .sent
            case .currentApp:
                await record("request:currentApp")
                return .currentApp(
                    try TVAppShortcut(
                        name: "Saved TV app", target: .vizio(appID: "synthetic-video", namespace: 3)))
            case .setKeyboardEnabled(let enabled):
                await record("request:keyboard:\(enabled)")
                var capabilities = television.capabilities
                if enabled && negotiated {
                    capabilities.insert(.textInput)
                } else {
                    capabilities.remove(.textInput)
                }
                television = television.applying(
                    TVSessionObservation(
                        stableDeviceKey: television.stableDeviceKey, powerState: .on,
                        protocolReportedCapabilities: capabilities))
                return .sent
            }
        }
        func sessionObservation() -> TVSessionObservation? {
            TVSessionObservation(
                stableDeviceKey: television.stableDeviceKey, powerState: .on,
                protocolReportedCapabilities: television.capabilities)
        }
        func disconnect() {}
        func forget(addressText: String) {}
        private func record(_ event: String) async { await MainActor.run { probe.lastEvent = event } }
    }
#endif
