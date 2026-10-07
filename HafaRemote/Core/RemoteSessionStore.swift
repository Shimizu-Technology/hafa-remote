import Foundation
import Observation

/// Main-actor projection of the session actor for SwiftUI screens.
@MainActor
@Observable
final class RemoteSessionStore {
    private(set) var state: RemoteSessionState = .idle
    private(set) var lastConnectedTV: ConnectedTV?
    private(set) var hasInitiatedConnection = false
    private var acceptsConnectedTVUpdates = true
    private var projectionRevision = 0

    private let controller: RemoteSessionController
    private let connectionWaitClock: any RemoteSessionClock
    private let stateSubscription = RemoteSessionStateSubscription()

    init(
        controller: RemoteSessionController,
        initialState: RemoteSessionState = .idle,
        connectionWaitClock: any RemoteSessionClock = ContinuousRemoteSessionClock(),
        beforeProjectingState: @escaping @Sendable (RemoteSessionState) async -> Void = { _ in }
    ) {
        self.controller = controller
        self.connectionWaitClock = connectionWaitClock
        state = initialState
        hasInitiatedConnection = initialState != .idle
        if case .connected(let tv) = initialState {
            lastConnectedTV = tv
        }
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
                    } else if self.connectedTV == nil {
                        self.lastConnectedTV = self.lastConnectedTV?.forgettingPowerObservation
                    }
                }
            }
        )
    }

    convenience init() {
        let samsung = SamsungPairingCoordinator(
            deviceInfoProvider: SamsungDeviceInfoClient(),
            credentialStore: KeychainSamsungPairingCredentialStore(),
            transport: SamsungCommandTransport()
        )
        let driver = MultiBrandSessionDriver(
            samsung: samsung,
            sony: SonyPairingCoordinator(),
            vizio: VizioPairingCoordinator(
                credentialStore: KeychainVizioPairingCredentialStore()
            )
        )
        self.init(controller: RemoteSessionController(driver: driver))
    }

    var connectedTV: ConnectedTV? {
        guard case .connected(let tv) = state else { return nil }
        return tv
    }

    var observedPowerState: TVPowerState { connectedTV?.powerState ?? .unknown }

    var canSendCommands: Bool {
        connectedTV != nil
    }

    func connect(to addressText: String) async {
        hasInitiatedConnection = true
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = true
        await controller.connect(to: addressText)
    }

    func connect(to target: TVConnectionTarget) async {
        guard !Task.isCancelled else { return }
        hasInitiatedConnection = true
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = true
        await controller.connect(to: target)
    }

    /// Starts one connection sequence and waits for its eventual connected state.
    func connectAndWait(
        to addressText: String,
        timeout: Duration
    ) async throws -> ConnectedTV {
        let states = await controller.states()
        let connectionWaitClock = connectionWaitClock

        return try await withThrowingTaskGroup(of: ConnectedTV?.self) { group in
            group.addTask {
                await self.connect(to: addressText)
                try Task.checkCancellation()
                return nil
            }
            group.addTask {
                for await state in states {
                    try Task.checkCancellation()
                    if case .connected(let tv) = state {
                        return tv
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                try await connectionWaitClock.sleep(for: timeout)
                try Task.checkCancellation()
                throw RemoteSessionControllerError.timedOut(.connect)
            }

            while let result = try await group.next() {
                if let connectedTV = result {
                    group.cancelAll()
                    return connectedTV
                }
            }
            throw RemoteSessionControllerError.timedOut(.connect)
        }
    }

    /// Connects to a saved brand-scoped target and ignores any stale state from another TV.
    func connectAndWait(
        to target: TVConnectionTarget,
        timeout: Duration,
        isStillSelected: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async throws -> ConnectedTV {
        try Task.checkCancellation()
        guard isStillSelected() else { throw CancellationError() }
        let states = await controller.states()
        try Task.checkCancellation()
        guard isStillSelected() else { throw CancellationError() }
        let connectionWaitClock = connectionWaitClock
        let expectedDeviceKey =
            "\(target.brand.rawValue):\(target.expectedSavedDeviceID ?? target.reportedDeviceID)"

        return try await withThrowingTaskGroup(of: ConnectedTV?.self) { group in
            group.addTask {
                try Task.checkCancellation()
                guard await isStillSelected() else { throw CancellationError() }
                await self.connect(to: target)
                try Task.checkCancellation()
                return nil
            }
            group.addTask {
                for await state in states {
                    try Task.checkCancellation()
                    guard await isStillSelected() else { throw CancellationError() }
                    if case .connected(let tv) = state, tv.stableDeviceKey == expectedDeviceKey {
                        return tv
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                try await connectionWaitClock.sleep(for: timeout)
                try Task.checkCancellation()
                throw RemoteSessionControllerError.timedOut(.connect)
            }

            while let result = try await group.next() {
                if let connectedTV = result {
                    group.cancelAll()
                    return connectedTV
                }
            }
            throw RemoteSessionControllerError.timedOut(.connect)
        }
    }

    func send(_ command: RemoteCommand, expectedDeviceKey: String? = nil) async throws {
        try await controller.send(command, expectedDeviceKey: expectedDeviceKey)
    }

    func sendText(_ input: RemoteTextInput, expectedDeviceKey: String? = nil) async throws {
        try await controller.sendText(input, expectedDeviceKey: expectedDeviceKey)
    }

    func convenience(_ request: TVConvenienceRequest, expectedDeviceKey: String) async throws
        -> TVConvenienceResponse
    {
        try await controller.convenience(request, expectedDeviceKey: expectedDeviceKey)
    }

    func refreshObservation() async { await controller.refreshObservation() }

    func submitPairingCode(_ code: String) async throws {
        try await controller.submitPairingCode(code)
    }

    func powerOffSelectedTV(expectedDeviceKey: String) async throws {
        let revision = projectionRevision
        let didDisconnect = try await controller.powerOffAndDisconnect(expectedDeviceKey: expectedDeviceKey)
        try Task.checkCancellation()
        guard didDisconnect, projectionRevision == revision,
            connectedTV == nil || connectedTV?.stableDeviceKey == expectedDeviceKey
        else { throw CancellationError() }
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = false
        if lastConnectedTV?.stableDeviceKey == expectedDeviceKey {
            lastConnectedTV = lastConnectedTV?.forgettingPowerObservation
        }
    }

    func disconnect(clearRememberedTV: Bool = true) async {
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = false
        if clearRememberedTV {
            lastConnectedTV = nil
        }
        await controller.disconnect()
    }

    func forgetPairing(
        for addressText: String,
        reportedDeviceID: String? = nil,
        brand: TVBrand = .samsung
    ) async throws {
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = false
        lastConnectedTV = nil
        try await controller.forgetPairing(
            for: addressText,
            reportedDeviceID: reportedDeviceID,
            brand: brand
        )
    }

    /// Removes an unselected TV's credential without altering the active remote session.
    func removePairingCredential(
        for addressText: String,
        reportedDeviceID: String? = nil,
        brand: TVBrand = .samsung
    ) async throws {
        try await controller.removePairingCredential(
            for: addressText,
            reportedDeviceID: reportedDeviceID,
            brand: brand
        )
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
