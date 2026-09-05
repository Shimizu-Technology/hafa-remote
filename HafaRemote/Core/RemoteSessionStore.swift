import Foundation
import Observation

/// Main-actor projection of the session actor for SwiftUI screens.
@MainActor
@Observable
final class RemoteSessionStore {
    private(set) var state: RemoteSessionState = .idle
    private(set) var lastConnectedTV: PairedSamsungTV?
    private var acceptsConnectedTVUpdates = true
    private var projectionRevision = 0

    private let controller: RemoteSessionController
    private let stateSubscription = RemoteSessionStateSubscription()

    init(
        controller: RemoteSessionController,
        beforeProjectingState: @escaping @Sendable (RemoteSessionState) async -> Void = { _ in }
    ) {
        self.controller = controller
        stateSubscription.install(
            Task { [weak self, controller] in
                let states = await controller.states()
                for await state in states {
                    guard !Task.isCancelled else { return }
                    let revision = self?.projectionRevision
                    await beforeProjectingState(state)
                    guard !Task.isCancelled, let self else { return }
                    guard revision == self.projectionRevision else { continue }
                    self.state = state
                    if case .connected(let tv) = state, self.acceptsConnectedTVUpdates {
                        self.lastConnectedTV = tv
                    }
                }
            }
        )
    }

    convenience init() {
        let coordinator = SamsungPairingCoordinator(
            deviceInfoProvider: SamsungDeviceInfoClient(),
            credentialStore: KeychainSamsungPairingCredentialStore(),
            transport: SamsungCommandTransport()
        )
        self.init(controller: RemoteSessionController(driver: coordinator))
    }

    var connectedTV: PairedSamsungTV? {
        guard case .connected(let tv) = state else { return nil }
        return tv
    }

    var canSendCommands: Bool {
        connectedTV != nil
    }

    func connect(to addressText: String) async {
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = true
        await controller.connect(to: addressText)
    }

    func send(_ command: RemoteCommand) async throws {
        try await controller.send(command)
    }

    func sendText(_ input: RemoteTextInput) async throws {
        try await controller.sendText(input)
    }

    func disconnect(clearRememberedTV: Bool = true) async {
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = false
        if clearRememberedTV {
            lastConnectedTV = nil
        }
        await controller.disconnect()
    }

    func forgetPairing(for addressText: String) async throws {
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = false
        lastConnectedTV = nil
        try await controller.forgetPairing(for: addressText)
    }

    func applicationDidEnterBackground() async {
        await controller.applicationDidEnterBackground()
    }

    func applicationWillEnterForeground() async {
        await controller.applicationWillEnterForeground()
    }

    func networkReachabilityChanged(isReachable: Bool) async {
        await controller.networkReachabilityChanged(isReachable: isReachable)
    }
}

/// Cancels the unstructured observation task when its owning store is released.
private final class RemoteSessionStateSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        precondition(self.task == nil, "A state subscription may only be installed once.")
        self.task = task
        lock.unlock()
    }

    deinit {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
