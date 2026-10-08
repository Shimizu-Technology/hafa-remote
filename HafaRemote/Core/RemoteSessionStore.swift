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
    private var stateRequestID: UUID?
    private var lastProjectedStateAt: ContinuousClock.Instant?
    let diagnostics: DiagnosticRecorder
    private var diagnosticDeviceKey: String?
    private var isAwaitingDiagnosticIdentity = false
    private var diagnosticConnectionStartedAt: ContinuousClock.Instant?
    private var diagnosticPairingStarted = false
    private var diagnosticConnectionCollection: DiagnosticCollectionToken?

    private let controller: RemoteSessionController
    private let connectionWaitClock: any RemoteSessionClock
    private let stateSubscription = RemoteSessionStateSubscription()

    init(
        controller: RemoteSessionController,
        initialState: RemoteSessionState = .idle,
        connectionWaitClock: any RemoteSessionClock = ContinuousRemoteSessionClock(),
        beforeProjectingState: @escaping @Sendable (RemoteSessionState) async -> Void = { _ in },
        diagnostics: DiagnosticRecorder? = nil
    ) {
        self.controller = controller
        self.diagnostics = diagnostics ?? DiagnosticRecorder()
        self.connectionWaitClock = connectionWaitClock
        state = initialState
        hasInitiatedConnection = initialState != .idle
        if case .connected(let tv) = initialState {
            lastConnectedTV = tv
            diagnosticDeviceKey = tv.stableDeviceKey
        }
        stateSubscription.install(
            Task { [weak self, controller] in
                let updates = await controller.stateUpdates()
                for await update in updates {
                    guard !Task.isCancelled else { return }
                    guard self != nil else { return }
                    if let expected = self?.stateRequestID, expected != update.requestID { continue }
                    let revision = self?.projectionRevision
                    let collection = self?.diagnostics.captureCollection(producedAt: update.activityStartedAt)
                    await beforeProjectingState(update.state)
                    guard !Task.isCancelled else { return }
                    guard await controller.ownsStateUpdate(update) else { continue }
                    guard let self else { return }
                    guard revision == self.projectionRevision,
                        self.stateRequestID == nil || self.stateRequestID == update.requestID
                    else { continue }
                    self.stateRequestID = update.requestID
                    self.project(update, collection: collection)
                }
            }
        )
    }

    convenience init() {
        guard TVBuildFlavor.isConfigured else {
            self.init(controller: RemoteSessionController(driver: DisabledRemoteSessionDriver()))
            return
        }
        let samsung = SamsungPairingCoordinator(
            deviceInfoProvider: SamsungDeviceInfoClient(),
            credentialStore: KeychainSamsungPairingCredentialStore(),
            transport: SamsungCommandTransport()
        )
        #if HAFA_PUBLIC_BUILD
            self.init(controller: RemoteSessionController(driver: samsung))
        #else
            let driver = MultiBrandSessionDriver(
                samsung: samsung,
                sony: SonyPairingCoordinator(),
                vizio: VizioPairingCoordinator(
                    credentialStore: KeychainVizioPairingCredentialStore()
                )
            )
            self.init(controller: RemoteSessionController(driver: driver))
        #endif
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
        _ = await performConnection(addressText: addressText, target: nil, requestID: UUID())
    }

    func connect(to target: TVConnectionTarget) async {
        _ = await performConnection(addressText: target.address.rawValue, target: target, requestID: UUID())
    }

    /// Provisional UI ownership must be reconciled if the controller never admitted it.
    private func performConnection(addressText: String, target: TVConnectionTarget?, requestID: UUID) async
        -> Bool
    {
        guard !Task.isCancelled else { return false }
        stateRequestID = requestID
        let expectedKey = target.flatMap { candidate in
            candidate.expectedSavedDeviceID.map { "\(candidate.brand.rawValue):\($0)" }
        }
        beginDiagnosticConnection(expectedDeviceKey: expectedKey)
        let activityStartedAt = diagnosticConnectionStartedAt ?? .now
        hasInitiatedConnection = true
        projectionRevision &+= 1
        let admissionRevision = projectionRevision
        acceptsConnectedTVUpdates = true
        if let target {
            await controller.connect(to: target, requestID: requestID, activityStartedAt: activityStartedAt)
        } else {
            await controller.connect(
                to: addressText, requestID: requestID, activityStartedAt: activityStartedAt)
        }
        guard stateRequestID == requestID, projectionRevision == admissionRevision else { return false }
        let ownership = await controller.producerOwnership()
        guard stateRequestID == requestID, projectionRevision == admissionRevision else { return false }
        guard ownership.requestID != requestID else { return true }

        // This is the controller's actual producer, not a restamped old consumer value.
        stateRequestID = ownership.requestID
        projectionRevision &+= 1
        let restorationRevision = projectionRevision
        clearDiagnosticScope()
        guard await controller.ownsStateUpdate(ownership.snapshot) else { return false }
        guard stateRequestID == ownership.requestID, projectionRevision == restorationRevision else {
            return false
        }
        project(ownership.snapshot, collection: nil, recordsEvents: false)
        diagnosticDeviceKey = connectedTV?.stableDeviceKey
        isAwaitingDiagnosticIdentity = connectedTV == nil
        return false
    }

    func connectAndWait(to addressText: String, timeout: Duration) async throws -> ConnectedTV {
        try await connectAndWait(addressText: addressText, target: nil, timeout: timeout)
    }

    func connectAndWait(
        to target: TVConnectionTarget, timeout: Duration,
        isStillSelected: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async throws -> ConnectedTV {
        try await connectAndWait(
            addressText: target.address.rawValue, target: target, timeout: timeout,
            isStillSelected: isStillSelected)
    }

    /// Old snapshots, including same-TV/ABA snapshots, cannot satisfy a new admission.
    private func connectAndWait(
        addressText: String, target: TVConnectionTarget?, timeout: Duration,
        isStillSelected: @escaping @MainActor @Sendable () -> Bool = { true }
    )
        async throws -> ConnectedTV
    {
        try Task.checkCancellation()
        guard isStillSelected() else { throw CancellationError() }
        let requestID = UUID()
        let updates = await controller.stateUpdates()
        try Task.checkCancellation()
        guard isStillSelected() else { throw CancellationError() }
        let controller = controller
        let clock = connectionWaitClock
        return try await withThrowingTaskGroup(of: ConnectedTV?.self) { group in
            group.addTask {
                try Task.checkCancellation()
                guard await isStillSelected() else { throw CancellationError() }
                let adopted = await self.performConnection(
                    addressText: addressText, target: target, requestID: requestID)
                try Task.checkCancellation()
                guard adopted else { throw CancellationError() }
                return nil
            }
            group.addTask {
                for await update in updates {
                    try Task.checkCancellation()
                    guard update.requestID == requestID, await controller.ownsStateUpdate(update),
                        case .connected(let television) = update.state
                    else { continue }
                    if let target {
                        guard television.brand == target.brand,
                            target.expectedSavedDeviceID == nil
                                || television.reportedDeviceID == target.expectedSavedDeviceID
                        else { continue }
                    }
                    guard await isStillSelected() else { throw CancellationError() }
                    return television
                }
                throw CancellationError()
            }
            group.addTask {
                try await clock.sleep(for: timeout)
                try Task.checkCancellation()
                throw RemoteSessionControllerError.timedOut(.connect)
            }
            while let value = try await group.next() {
                if let television = value {
                    group.cancelAll()
                    guard isStillSelected() else { throw CancellationError() }
                    return television
                }
            }
            throw RemoteSessionControllerError.timedOut(.connect)
        }
    }

    private func project(
        _ update: RemoteSessionStateUpdate, collection: DiagnosticCollectionToken?, recordsEvents: Bool = true
    ) {
        guard lastProjectedStateAt.map({ update.producedAt >= $0 }) ?? true else { return }
        if recordsEvents {
            recordDiagnosticState(
                update.state, replacing: state, collection: collection,
                activityStartedAt: update.activityStartedAt)
        }
        lastProjectedStateAt = update.producedAt
        state = update.state
        if case .connected(let television) = state, acceptsConnectedTVUpdates {
            lastConnectedTV = television
        } else if connectedTV == nil {
            lastConnectedTV = lastConnectedTV?.forgettingPowerObservation
        }
    }

    func send(_ command: RemoteCommand, expectedDeviceKey: String? = nil) async throws {
        let startedAt = ContinuousClock.now
        let scope = diagnosticDeviceKey
        let collection = diagnostics.captureCollection()
        do {
            try await controller.send(
                command, expectedDeviceKey: expectedDeviceKey, activityStartedAt: startedAt)
            recordDiagnosticDelivery(.commandSent, since: startedAt, scope: scope, collection: collection)
        } catch {
            if !(error is CancellationError) {
                recordDiagnosticDelivery(
                    .commandDeliveryFailed, since: startedAt, scope: scope, collection: collection)
            }
            throw error
        }
    }

    func sendText(_ input: RemoteTextInput, expectedDeviceKey: String? = nil) async throws {
        let startedAt = ContinuousClock.now
        let scope = diagnosticDeviceKey
        let collection = diagnostics.captureCollection()
        do {
            try await controller.sendText(
                input, expectedDeviceKey: expectedDeviceKey, activityStartedAt: startedAt)
            recordDiagnosticDelivery(.textSent, since: startedAt, scope: scope, collection: collection)
        } catch {
            if !(error is CancellationError) {
                recordDiagnosticDelivery(
                    .textDeliveryFailed, since: startedAt, scope: scope, collection: collection)
            }
            throw error
        }
    }

    func convenience(_ request: TVConvenienceRequest, expectedDeviceKey: String) async throws
        -> TVConvenienceResponse
    {
        let startedAt = ContinuousClock.now
        let scope = diagnosticDeviceKey
        let collection = diagnostics.captureCollection()
        do {
            let response = try await controller.convenience(
                request, expectedDeviceKey: expectedDeviceKey,
                activityStartedAt: startedAt)
            if request.changesTVState {
                recordDiagnosticDelivery(.commandSent, since: startedAt, scope: scope, collection: collection)
            }
            return response
        } catch {
            if request.changesTVState, !(error is CancellationError) {
                recordDiagnosticDelivery(
                    .commandDeliveryFailed, since: startedAt, scope: scope, collection: collection)
            }
            throw error
        }
    }

    func refreshObservation() async { await controller.refreshObservation() }

    func submitPairingCode(_ code: String) async throws {
        try await controller.submitPairingCode(code)
    }

    func powerOffSelectedTV(expectedDeviceKey: String) async throws {
        let revision = projectionRevision
        let startedAt = ContinuousClock.now
        let scope = diagnosticDeviceKey
        let collection = diagnostics.captureCollection()
        let didDisconnect: Bool
        do {
            didDisconnect = try await controller.powerOffAndDisconnect(
                expectedDeviceKey: expectedDeviceKey,
                activityStartedAt: startedAt)
            recordDiagnosticDelivery(.commandSent, since: startedAt, scope: scope, collection: collection)
        } catch {
            if !(error is CancellationError) {
                recordDiagnosticDelivery(
                    .commandDeliveryFailed, since: startedAt, scope: scope, collection: collection)
            }
            throw error
        }
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
            clearDiagnosticScope()
        }
        await controller.disconnect()
    }

    func forgetPairing(
        for addressText: String,
        reportedDeviceID: String? = nil,
        brand: TVBrand = .samsung
    ) async throws {
        guard TVDistributionPolicy.current.permits(brand) else {
            throw RemoteCredentialRemovalError.unsupported
        }
        projectionRevision &+= 1
        acceptsConnectedTVUpdates = false
        lastConnectedTV = nil
        clearDiagnosticScope()
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
        guard TVDistributionPolicy.current.permits(brand) else {
            throw RemoteCredentialRemovalError.unsupported
        }
        try await controller.removePairingCredential(
            for: addressText,
            reportedDeviceID: reportedDeviceID,
            brand: brand
        )
    }

    func applicationDidEnterBackground() async {
        let startedAt = ContinuousClock.now
        diagnostics.record(.appBackgrounded)
        await controller.applicationDidEnterBackground(activityStartedAt: startedAt)
    }

    func applicationWillEnterForeground() async {
        let startedAt = ContinuousClock.now
        diagnostics.record(.appForegrounded)
        await controller.applicationWillEnterForeground(activityStartedAt: startedAt)
    }

    /// Metadata is taken only from the current authenticated session, never a saved display name.
    var diagnosticMetadata: DiagnosticMetadata {
        guard let television = connectedTV, television.stableDeviceKey == diagnosticDeviceKey else {
            return .current()
        }
        return .current(verifiedTV: television)
    }

    func recordWakeRequested(for stableDeviceKey: String) -> DiagnosticCollectionToken? {
        guard stableDeviceKey == diagnosticDeviceKey else { return nil }
        let collection = diagnostics.captureCollection()
        diagnostics.record(.wakeRequested, collection: collection)
        return collection
    }

    func recordWakeUnavailable(for stableDeviceKey: String, collection: DiagnosticCollectionToken?) {
        guard stableDeviceKey == diagnosticDeviceKey else { return }
        diagnostics.record(.wakeUnavailable, collection: collection)
    }

    private func clearDiagnosticScope() {
        diagnostics.clear()
        diagnosticDeviceKey = nil
        isAwaitingDiagnosticIdentity = false
        diagnosticConnectionStartedAt = nil
        diagnosticPairingStarted = false
        diagnosticConnectionCollection = nil
    }

    private func beginDiagnosticConnection(expectedDeviceKey: String?) {
        if expectedDeviceKey == nil || expectedDeviceKey != diagnosticDeviceKey { diagnostics.clear() }
        diagnosticDeviceKey = expectedDeviceKey
        isAwaitingDiagnosticIdentity = expectedDeviceKey == nil
        diagnosticConnectionStartedAt = .now
        diagnosticPairingStarted = false
        diagnosticConnectionCollection = diagnostics.captureCollection()
        diagnostics.record(.connectionStarted, collection: diagnosticConnectionCollection)
    }

    private func recordDiagnosticState(
        _ next: RemoteSessionState, replacing previous: RemoteSessionState,
        collection: DiagnosticCollectionToken?, activityStartedAt: ContinuousClock.Instant
    ) {
        switch next {
        case .connecting:
            if diagnosticConnectionStartedAt != activityStartedAt {
                diagnosticConnectionStartedAt = activityStartedAt
                diagnosticConnectionCollection = collection
                diagnostics.record(.connectionStarted, collection: collection)
            }
        case .reconnecting:
            diagnosticConnectionStartedAt = activityStartedAt
            diagnosticConnectionCollection = collection
            if next != previous { diagnostics.record(.reconnectStarted, collection: collection) }
        case .pairing:
            diagnosticPairingStarted = true
            diagnostics.record(.pairingStarted, collection: collection)
        case .connected(let television):
            if let expected = diagnosticDeviceKey, expected != television.stableDeviceKey,
                !isAwaitingDiagnosticIdentity
            {
                return
            }
            if case .connected(let prior) = previous, prior.stableDeviceKey == television.stableDeviceKey {
                return
            }
            diagnosticDeviceKey = television.stableDeviceKey
            isAwaitingDiagnosticIdentity = false
            if diagnosticPairingStarted {
                diagnostics.record(.pairingApproved, collection: collection)
            }
            diagnostics.record(
                .connectionReady, durationSeconds: diagnosticConnectionStartedAt.map(Self.secondsSince),
                collection: collection)
            diagnosticConnectionStartedAt = nil
            diagnosticPairingStarted = false
        case .offline:
            diagnostics.record(.connectionUnavailable, collection: collection)
        case .denied:
            diagnostics.record(.pairingDenied, collection: collection)
        case .savedPairingRejected:
            diagnostics.record(.pairingExpired, collection: collection)
        case .certificateChanged:
            diagnostics.record(.certificateChanged, collection: collection)
        case .failed(.timedOut(.connect)):
            diagnostics.record(.connectionTimedOut, collection: collection)
        case .failed(.timedOut(.send)):
            break
        case .failed, .unsupported:
            diagnostics.record(.connectionUnavailable, collection: collection)
        case .idle:
            break
        }
    }

    private func recordDiagnosticDelivery(
        _ kind: DiagnosticEventKind, since startedAt: ContinuousClock.Instant, scope: String?,
        collection: DiagnosticCollectionToken?
    ) {
        guard scope == diagnosticDeviceKey else { return }
        diagnostics.record(kind, durationSeconds: Self.secondsSince(startedAt), collection: collection)
    }

    private static func secondsSince(_ instant: ContinuousClock.Instant) -> TimeInterval {
        let components = instant.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    func networkReachabilityChanged(isReachable: Bool) async {
        await controller.networkReachabilityChanged(isReachable: isReachable, activityStartedAt: .now)
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
