import Foundation
import Observation

/// Main-actor projection of the session actor for SwiftUI screens.
@MainActor
@Observable
final class RemoteSessionStore {
    private(set) var state: RemoteSessionState = .idle

    private let controller: RemoteSessionController
    private let stateSubscription = RemoteSessionStateSubscription()

    init(controller: RemoteSessionController) {
        self.controller = controller
        stateSubscription.install(
            Task { [weak self, controller] in
                let states = await controller.states()
                for await state in states {
                    guard !Task.isCancelled else { return }
                    self?.state = state
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
        await controller.connect(to: addressText)
    }

    func send(_ command: RemoteCommand) async throws {
        try await controller.send(command)
    }

    func disconnect() async {
        await controller.disconnect()
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
