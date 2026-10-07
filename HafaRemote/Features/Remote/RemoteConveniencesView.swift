import SwiftUI

struct RemoteConvenienceContext {
    let stableDeviceKey: String
    let brand: TVBrand
    var preferences: TVConveniencePreferences? = nil
    let request: @MainActor @Sendable (TVConvenienceRequest) async throws -> TVConvenienceResponse
}

/// Optional features use the same selected session; nothing opens an external URL.
struct RemoteConveniencesView: View {
    @Environment(\.scenePhase) private var scenePhase
    let context: RemoteConvenienceContext
    let capabilities: Set<TVCapability>
    let isConnected: Bool
    let send: @MainActor @Sendable (RemoteCommand) async -> Void
    @State private var preferences: TVConveniencePreferences
    @State private var apps: [TVAppShortcut] = []
    @State private var inputs: [TVInputSource] = []
    @State private var job: Task<Void, Never>?
    @State private var jobID: UUID?
    @State private var message: String?
    @State private var currentApp: TVAppShortcut?
    @State private var appName = ""
    @State private var isNamingApp = false

    init(
        context: RemoteConvenienceContext, capabilities: Set<TVCapability>, isConnected: Bool,
        send: @escaping @MainActor @Sendable (RemoteCommand) async -> Void
    ) {
        self.context = context
        self.capabilities = capabilities
        self.isConnected = isConnected
        self.send = send
        _preferences = State(initialValue: context.preferences ?? .shared)
    }

    var body: some View {
        Form {
            if !isConnected {
                Section { Label("Reconnect to use these controls.", systemImage: "wifi.exclamationmark") }
            }
            if capabilities.contains(.sourceMenu) {
                Section("Inputs") {
                    commandButton(.inputSource, name: "Open TV Inputs", symbol: "rectangle.on.rectangle")
                    if capabilities.contains(.inputSelection) || context.brand == .vizio {
                        ForEach(inputs) { input in
                            Button(input.name) { perform(.selectInput(input)) }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("convenienceInput-\(input.value)")
                        }
                        Button("Refresh Inputs", systemImage: "arrow.clockwise") { perform(.inputs) }
                            .frame(minHeight: 44)
                    }
                }
            }
            if capabilities.contains(.channels) {
                Section("Channels") {
                    commandButton(.channelUp, name: "Channel Up", symbol: "plus")
                    commandButton(.channelDown, name: "Channel Down", symbol: "minus")
                    if capabilities.contains(.guide) {
                        commandButton(.guide, name: "TV Guide", symbol: "list.bullet.rectangle")
                    }
                    if capabilities.contains(.numberPad) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                            ForEach(RemoteCommand.allCases.filter { $0.digit != nil }, id: \.self) {
                                command in
                                Button {
                                    sendCommand(command)
                                } label: {
                                    Text(String(command.digit ?? 0))
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("TV digit \(command.digit ?? 0)")
                                .accessibilityIdentifier("convenience-\(command.rawValue)")
                            }
                        }
                    }
                }
            }
            if capabilities.contains(.favoriteApps) || context.brand == .samsung || context.brand == .vizio {
                Section {
                    ForEach(preferences.favorites(for: context.stableDeviceKey)) { app in
                        appRow(app, favorited: true, inFavorites: true)
                    }
                    if preferences.favorites(for: context.stableDeviceKey).isEmpty {
                        Text("Choose a favorite below for this TV.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Favorite Apps")
                } footer: {
                    Text(
                        "Favorites stay on this phone and belong to this TV. A sent launch request does not confirm that the app opened."
                    )
                }
                if context.brand == .vizio {
                    Section {
                        Button("Save Current TV App", systemImage: "star") { perform(.currentApp) }
                            .frame(minHeight: 44)
                    } footer: {
                        Text(
                            "Open an app on the TV first, then save its launch configuration. Apps requiring a media or casting payload cannot be saved."
                        )
                    }
                } else {
                    Section {
                        ForEach(apps) { app in
                            appRow(
                                app,
                                favorited: preferences.favorites(for: context.stableDeviceKey).contains(
                                    where: { $0.target == app.target }))
                        }
                        Button("Refresh Apps", systemImage: "arrow.clockwise") { perform(.apps) }
                            .frame(minHeight: 44)
                    } header: {
                        Text(context.brand == .sony ? "Configured App Links" : "Apps Reported by TV")
                    } footer: {
                        Text(
                            context.brand == .sony
                                ? "These links are not an installed-app inventory. Test each on your TV before saving it as a favorite."
                                : "Some Samsung TVs do not provide an app list. Ordinary remote controls remain available."
                        )
                    }
                }
            }
            if context.brand == .sony {
                Section {
                    Toggle(
                        "Remote Keyboard",
                        isOn: Binding(
                            get: { preferences.keyboardEnabled(for: context.stableDeviceKey) },
                            set: { perform(.setKeyboardEnabled($0)) }
                        )
                    )
                    .accessibilityIdentifier("remoteKeyboardPreference")
                } footer: {
                    Text(
                        "Turn off if the TV's onscreen keyboard becomes unavailable. Text requires a newly focused TV field and current protocol counters."
                    )
                }
            }
            if job != nil { Section { ProgressView("Requesting from TV…") } }
            if let message {
                Section {
                    Text(message).foregroundStyle(.secondary).accessibilityIdentifier("convenienceResult")
                }
            }
        }
        .disabled(!isConnected || job != nil)
        .navigationTitle("More Controls")
        .tint(HafaTheme.accent)
        .task(id: context.stableDeviceKey) {
            if isConnected
                && (context.brand == .samsung
                    || (capabilities.contains(.favoriteApps) && context.brand == .sony))
            {
                perform(.apps)
            } else if isConnected, context.brand == .vizio {
                perform(.inputs)
            }
        }
        .onDisappear { cancel() }
        .onChange(of: isConnected) { _, connected in if !connected { cancel() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
        .alert("Name this favorite", isPresented: $isNamingApp) {
            TextField("App name", text: $appName)
            Button("Save") {
                guard let currentApp, let named = try? TVAppShortcut(name: appName, target: currentApp.target)
                else { return }
                if !preferences.favorites(for: context.stableDeviceKey).contains(where: {
                    $0.target == named.target
                }) {
                    do { try preferences.toggleFavorite(named, for: context.stableDeviceKey) } catch {
                        message = "This favorite could not be saved."
                    }
                }
                self.currentApp = nil
                appName = ""
            }
            Button("Cancel", role: .cancel) {
                currentApp = nil
                appName = ""
            }
        } message: {
            Text("The name is saved only on this phone.")
        }
    }

    private func commandButton(_ command: RemoteCommand, name: String, symbol: String) -> some View {
        Button(name, systemImage: symbol) { sendCommand(command) }
            .frame(minHeight: 44)
            .accessibilityIdentifier("convenience-\(command.rawValue)")
    }

    private func appRow(_ app: TVAppShortcut, favorited: Bool, inFavorites: Bool = false) -> some View {
        HStack {
            Button {
                perform(.launch(app))
            } label: {
                Text(app.name)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Requests this app on the selected TV.")
            .accessibilityIdentifier("\(inFavorites ? "favorite" : "available")App-\(app.name)")
            .disabled(
                !capabilities.contains(.favoriteApps)
                    && !apps.contains(where: { $0.target == app.target }))
            Button {
                do { try preferences.toggleFavorite(app, for: context.stableDeviceKey) } catch {
                    message = "This favorite could not be saved. Keep up to 12 favorites per TV."
                }
            } label: {
                Image(systemName: favorited ? "star.fill" : "star")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(favorited ? "Remove" : "Save") \(app.name) favorite")
            .accessibilityIdentifier("toggleFavorite-\(inFavorites ? "favorite" : "available")-\(app.name)")
        }
    }

    private func sendCommand(_ command: RemoteCommand) {
        guard job == nil, isConnected, scenePhase == .active else { return }
        let id = UUID()
        jobID = id
        job = Task { @MainActor in
            await send(command)
            if jobID == id {
                jobID = nil
                job = nil
            }
        }
    }

    private func perform(_ request: TVConvenienceRequest) {
        guard job == nil, isConnected, scenePhase == .active else { return }
        let id = UUID()
        jobID = id
        message = nil
        job = Task { @MainActor in
            defer {
                if jobID == id {
                    jobID = nil
                    job = nil
                }
            }
            do {
                let response = try await context.request(request)
                try Task.checkCancellation()
                guard jobID == id else { return }
                switch response {
                case .apps(let list):
                    apps = list
                    if list.isEmpty { message = "No apps were reported by this TV." }
                case .inputs(let list): inputs = list
                case .currentApp(let app):
                    guard let app else {
                        message =
                            "No app launch configuration is available. Open an app on the TV and try again."
                        return
                    }
                    currentApp = app
                    appName = ""
                    isNamingApp = true
                case .sent:
                    if case .setKeyboardEnabled(let enabled) = request {
                        try preferences.setKeyboardEnabled(enabled, for: context.stableDeviceKey)
                        message =
                            enabled
                            ? "Remote keyboard enabled when the TV supports it." : "Remote keyboard disabled."
                    } else {
                        message = "Request sent. Check the TV for the result."
                    }
                }
            } catch is CancellationError {} catch {
                guard jobID == id else { return }
                message =
                    (error as? TVConvenienceError)?.errorDescription
                    ?? "The TV could not provide this feature. Reconnect and try again."
            }
        }
    }

    private func cancel() {
        jobID = nil
        job?.cancel()
        job = nil
        currentApp = nil
        appName = ""
        isNamingApp = false
    }
}

struct RemoteSwipeControl: View {
    @Environment(\.scenePhase) private var scenePhase
    let isEnabled: Bool
    let action: @MainActor @Sendable (RemoteCommand) async -> Void
    @State private var commandTask: Task<Void, Never>?
    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(HafaTheme.surface)
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "hand.draw").font(.title)
                    Text("Swipe to move · Tap to select").font(.subheadline)
                }
                .foregroundStyle(HafaTheme.primaryText)
                .padding()
            }
            .frame(minHeight: 210)
            .contentShape(RoundedRectangle(cornerRadius: 28))
            .gesture(
                DragGesture(minimumDistance: 10).onEnded { value in
                    if let command = RemoteSwipeMapping.command(
                        horizontal: value.translation.width, vertical: value.translation.height)
                    {
                        send(command)
                    }
                }
            )
            .simultaneousGesture(TapGesture().onEnded { send(.select) })
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Swipe navigation")
            .accessibilityHint("Use Buttons for individual accessible direction controls.")
            .accessibilityAction(named: "Up") { send(.up) }
            .accessibilityAction(named: "Down") { send(.down) }
            .accessibilityAction(named: "Left") { send(.left) }
            .accessibilityAction(named: "Right") { send(.right) }
            .accessibilityAction(named: "Select") { send(.select) }
            .accessibilityIdentifier("remoteSwipeControl")
            .onDisappear {
                commandTask?.cancel()
                commandTask = nil
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    commandTask?.cancel()
                    commandTask = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    commandTask?.cancel()
                    commandTask = nil
                }
            }
    }
    private func send(_ command: RemoteCommand) {
        guard isEnabled, scenePhase == .active else { return }
        commandTask?.cancel()
        commandTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await action(command)
        }
    }
}
