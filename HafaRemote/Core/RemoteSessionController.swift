import Foundation
import OSLog

protocol RemoteSessionDriving: TVDriver {
    var brand: TVBrand { get }
    func supports(_ brand: TVBrand) -> Bool
    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV
    func connect(
        to target: TVConnectionTarget,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV
    func forget(addressText: String) async throws
    func forget(addressText: String, reportedDeviceID: String?, brand: TVBrand) async throws
    /// Deletes one saved credential without requiring the active transport to disconnect.
    func removeCredential(addressText: String, reportedDeviceID: String?, brand: TVBrand) async throws
    func submitPairingCode(_ code: String) async throws
}

extension RemoteSessionDriving {
    var brand: TVBrand { .samsung }

    func connect(
        to target: TVConnectionTarget,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
        let television = try await connect(
            addressText: target.address.rawValue,
            onWaitingForApproval: onWaitingForApproval
        )
        do {
            try target.validateConnectedIdentity(television)
        } catch {
            await disconnect()
            throw error
        }
        return television.applyingDiscoveryMetadata(from: target)
    }

    func forget(addressText: String, reportedDeviceID: String?, brand: TVBrand) async throws {
        try await forget(addressText: addressText)
    }

    /// Refuses to infer that an existing forget operation is safe for an active transport.
    func removeCredential(
        addressText: String,
        reportedDeviceID: String?,
        brand: TVBrand
    ) async throws {
        throw RemoteCredentialRemovalError.unsupported
    }

    func supports(_ brand: TVBrand) -> Bool {
        brand == self.brand
    }

    func submitPairingCode(_ code: String) async throws {
        throw MultiBrandSessionDriverError.pairingCodeNotExpected
    }
}

extension SamsungPairingCoordinator: RemoteSessionDriving {
    nonisolated var brand: TVBrand { .samsung }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
        try await pair(
            addressText: addressText,
            onWaitingForApproval: onWaitingForApproval
        )
    }

    func connect(
        to target: TVConnectionTarget,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
        guard target.brand == .samsung,
            target.controlPort == nil || target.controlPort == 8002
        else {
            throw SamsungPairingCoordinatorError.unsupportedTokenAuthentication
        }
        return try await pair(
            target: target,
            onWaitingForApproval: onWaitingForApproval
        )
    }

    /// Bridges the generic session boundary to Samsung's non-destructive credential API.
    func removeCredential(
        addressText: String,
        reportedDeviceID: String?,
        brand: TVBrand
    ) async throws {
        guard brand == .samsung else { throw RemoteCredentialRemovalError.unsupported }
        try await removeCredential(
            addressText: addressText,
            reportedDeviceID: reportedDeviceID
        )
    }
}

protocol RemoteSessionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousRemoteSessionClock: RemoteSessionClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct RemoteSessionConfiguration: Equatable, Sendable {
    let connectionTimeout: Duration
    let pairingTimeout: Duration
    let commandTimeout: Duration
    let disconnectTimeout: Duration
    let pairingRemovalTimeout: Duration
    let reconnectDelays: [Duration]
    let repeatsLastReconnectDelay: Bool
    let healthCheckInterval: Duration?
    let healthCheckTimeout: Duration
    let healthCheckRetryDelay: Duration
    let healthFailureThreshold: Int
    let networkLossGracePeriod: Duration

    static let production = RemoteSessionConfiguration(
        connectionTimeout: .seconds(12),
        pairingTimeout: .seconds(60),
        commandTimeout: .seconds(3),
        disconnectTimeout: .seconds(2),
        pairingRemovalTimeout: .seconds(3),
        reconnectDelays: [.milliseconds(250), .seconds(1), .seconds(2), .seconds(5), .seconds(10)],
        repeatsLastReconnectDelay: false,
        healthCheckInterval: .seconds(15),
        healthCheckTimeout: .seconds(16),
        healthCheckRetryDelay: .seconds(3),
        healthFailureThreshold: 2,
        networkLossGracePeriod: .seconds(2)
    )
}

enum RemoteSessionControllerError: Error, Equatable, Sendable {
    case notConnected
    case timedOut(RemoteSessionOperation)

    var operation: RemoteSessionOperation {
        switch self {
        case .notConnected:
            .send
        case .timedOut(let operation):
            operation
        }
    }
}

enum RemoteCredentialRemovalError: Error, Equatable, Sendable {
    case unsupported
}

/// Owns the single driver session, lifecycle cancellation, health checks, and reconnect policy.
actor RemoteSessionController {
    private static let logger = Logger(
        subsystem: "com.shimizutechnology.hafaremote",
        category: "RemoteSession"
    )

    private(set) var state: RemoteSessionState

    private let driver: any RemoteSessionDriving
    private let clock: any RemoteSessionClock
    private let configuration: RemoteSessionConfiguration
    private let commandSerializer = RemoteSessionCommandSerializer()

    private var isForeground = true
    private var lastNetworkReachability: Bool?
    private var targetAddressText: String?
    private var connectionTarget: TVConnectionTarget?
    private var generation = UUID()
    private var reconnectAttempt = 0

    private var connectionID: UUID?
    private var connectionTask: Task<ConnectedTV, Error>?
    private var driverTeardownID: UUID?
    private var driverTeardownTask: Task<Void, Never>?
    private var recoveryAfterDriverTeardownGeneration: UUID?
    private var pairingRemovalID: UUID?
    private var pairingRemovalWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var healthScheduleTask: Task<Void, Never>?
    private var healthProbeID: UUID?
    private var healthProbeTask: Task<TVSessionObservation?, Error>?
    private var observationTask: Task<Void, Never>?
    private var consecutiveHealthFailures = 0
    private var networkLossTask: Task<Void, Never>?
    private var pendingCommandCount = 0
    private var commandTasks: [UUID: Task<Void, Error>] = [:]
    private var stateRequestID = UUID()
    private var publishedStateRequestID: UUID?
    private var publishedStateGeneration: UUID?
    private var publishedStateProducedAt: ContinuousClock.Instant = .now
    private var publishedActivityStartedAt: ContinuousClock.Instant = .now
    private var stateUpdateContinuations: [UUID: AsyncStream<RemoteSessionStateUpdate>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<RemoteSessionState>.Continuation] = [:]

    init(
        driver: any RemoteSessionDriving,
        clock: any RemoteSessionClock = ContinuousRemoteSessionClock(),
        configuration: RemoteSessionConfiguration = .production,
        initialState: RemoteSessionState = .idle
    ) {
        self.driver = driver
        self.clock = clock
        self.configuration = configuration
        state = initialState
        publishedStateRequestID = stateRequestID
        publishedStateGeneration = generation
        publishedStateProducedAt = .now
    }

    func states() -> AsyncStream<RemoteSessionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RemoteSessionState>.makeStream()
        stateContinuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeStateContinuation(id)
            }
        }
        return stream
    }

    func stateUpdates() -> AsyncStream<RemoteSessionStateUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RemoteSessionStateUpdate>.makeStream()
        stateUpdateContinuations[id] = continuation
        continuation.yield(currentStateUpdate())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateUpdateContinuation(id) }
        }
        return stream
    }

    func ownsStateUpdate(_ update: RemoteSessionStateUpdate) -> Bool {
        update.requestID == stateRequestID && update.generation == generation
    }

    func producerOwnership() -> RemoteSessionProducerOwnership {
        RemoteSessionProducerOwnership(requestID: stateRequestID, snapshot: currentStateUpdate())
    }

    private func currentStateUpdate() -> RemoteSessionStateUpdate {
        RemoteSessionStateUpdate(
            state: state, requestID: publishedStateRequestID ?? stateRequestID,
            generation: publishedStateGeneration ?? generation, producedAt: publishedStateProducedAt,
            activityStartedAt: publishedActivityStartedAt)
    }

    private func removeStateUpdateContinuation(_ id: UUID) { stateUpdateContinuations[id] = nil }

    func connect(
        to addressText: String, requestID: UUID = UUID(), activityStartedAt: ContinuousClock.Instant = .now
    ) async {
        await beginConnection(
            to: addressText, target: nil, requestID: requestID, activityStartedAt: activityStartedAt)
    }

    func connect(
        to target: TVConnectionTarget, requestID: UUID = UUID(),
        activityStartedAt: ContinuousClock.Instant = .now
    ) async {
        guard !Task.isCancelled else { return }
        guard driver.supports(target.brand) else {
            stateRequestID = requestID
            generation = UUID()
            targetAddressText = nil
            connectionTarget = nil
            reconnectAttempt = 0
            await cancelInFlightWork()
            await disconnectDriverWithinLimit()
            transition(to: .unsupported, activityStartedAt: activityStartedAt)
            return
        }
        await beginConnection(
            to: target.address.rawValue, target: target, requestID: requestID,
            activityStartedAt: activityStartedAt)
    }

    private func beginConnection(
        to addressText: String,
        target: TVConnectionTarget?,
        requestID: UUID,
        activityStartedAt: ContinuousClock.Instant
    ) async {
        do {
            try await waitForPairingRemoval()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            generation = UUID()
            stateRequestID = requestID
            transition(to: .failed(.timedOut(.forgetPairing)), activityStartedAt: activityStartedAt)
            return
        }
        guard !Task.isCancelled else { return }
        generation = UUID()
        stateRequestID = requestID
        let requestedGeneration = generation
        targetAddressText = addressText
        connectionTarget = target
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil

        await cancelInFlightWork()
        await disconnectDriverWithinLimit()
        guard generation == requestedGeneration else { return }
        guard isForeground else {
            transition(to: .offline, activityStartedAt: activityStartedAt)
            return
        }
        await attemptConnection(
            generation: requestedGeneration, isReconnect: false, activityStartedAt: activityStartedAt)
    }

    func send(_ command: RemoteCommand, expectedDeviceKey: String? = nil, activityStartedAt: ContinuousClock.Instant = .now) async throws {
        let requestedGeneration = generation
        if let expectedDeviceKey {
            guard case .connected(let tv) = state, tv.stableDeviceKey == expectedDeviceKey else {
                throw TVConvenienceError.wrongTV
            }
        }
        if case .connected(let television) = state,
            !television.capabilities.contains(command.requiredCapability)
        {
            throw TVDriverError.unsupportedCommand
        }
        try await performSend(recoverCancelledWrite: true, activityStartedAt: activityStartedAt) { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.executeCommand(
                command, expectedDeviceKey: expectedDeviceKey, generation: requestedGeneration)
        }
    }

    private func executeCommand(
        _ command: RemoteCommand, expectedDeviceKey: String?, generation requestedGeneration: UUID
    ) async throws {
        try Task.checkCancellation()
        guard generation == requestedGeneration, isForeground, case .connected(let tv) = state,
            expectedDeviceKey == nil || expectedDeviceKey == tv.stableDeviceKey
        else { throw CancellationError() }
        guard tv.capabilities.contains(command.requiredCapability) else {
            throw TVDriverError.unsupportedCommand
        }
        try await driver.send(command)
    }

    func sendText(_ input: RemoteTextInput, expectedDeviceKey: String? = nil, activityStartedAt: ContinuousClock.Instant = .now) async throws {
        let requestedGeneration = generation
        try await performSend(recoverCancelledWrite: true, activityStartedAt: activityStartedAt) { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.executeText(
                input, expectedDeviceKey: expectedDeviceKey, generation: requestedGeneration)
        }
    }

    private func executeText(
        _ input: RemoteTextInput, expectedDeviceKey: String?, generation requestedGeneration: UUID
    ) async throws {
        try Task.checkCancellation()
        guard generation == requestedGeneration, isForeground, case .connected(let tv) = state,
            expectedDeviceKey == nil || expectedDeviceKey == tv.stableDeviceKey
        else { throw CancellationError() }
        try await driver.sendText(input)
    }

    func convenience(_ request: TVConvenienceRequest, expectedDeviceKey: String) async throws
        -> TVConvenienceResponse
    {
        guard case .connected(let tv) = state, tv.stableDeviceKey == expectedDeviceKey, isForeground else {
            throw TVConvenienceError.wrongTV
        }
        let requestedGeneration = generation
        let box = TVConvenienceResultBox()
        try await performSend(
            optionalFeature: !request.changesTVState, isConvenienceRequest: true,
            recoverCancelledWrite: request.changesTVState,
            timeout: .seconds(10)
        ) { [weak self] in
            guard let self else { throw CancellationError() }
            let response = try await self.executeConvenience(
                request, expectedDeviceKey: expectedDeviceKey, generation: requestedGeneration)
            await box.store(response)
        }
        guard generation == requestedGeneration, isForeground, case .connected(let current) = state,
            current.stableDeviceKey == expectedDeviceKey
        else { throw CancellationError() }
        let response = try await box.value()
        await refreshObservation()
        guard generation == requestedGeneration else { throw CancellationError() }
        return response
    }

    private func executeConvenience(
        _ request: TVConvenienceRequest, expectedDeviceKey: String, generation requestedGeneration: UUID
    ) async throws -> TVConvenienceResponse {
        try Task.checkCancellation()
        guard generation == requestedGeneration, isForeground, case .connected(let tv) = state,
            tv.stableDeviceKey == expectedDeviceKey
        else { throw CancellationError() }
        return try await driver.convenience(request)
    }

    /// Refreshes optional power evidence after an explicit action without claiming success.
    func refreshObservation() async {
        guard case .connected(let television) = state else { return }
        let requestedGeneration = generation
        let driver = driver
        let clock = clock
        do {
            let observation = try await RemoteSessionTimeout.run(
                operation: .healthCheck, timeout: .seconds(3), clock: clock
            ) { try await driver.sessionObservation() }
            guard !Task.isCancelled else { return }
            if let observation { applyObservation(observation, generation: requestedGeneration) }
        } catch {
            guard !Task.isCancelled else { return }
            applyObservation(
                TVSessionObservation(stableDeviceKey: television.stableDeviceKey, powerState: .unknown),
                generation: requestedGeneration
            )
        }
    }

    func submitPairingCode(_ code: String) async throws {
        try await driver.submitPairingCode(code)
    }

    private func performSend(
        optionalFeature: Bool = false,
        isConvenienceRequest: Bool = false,
        recoverCancelledWrite: Bool = false,
        timeout requestedTimeout: Duration? = nil,
        activityStartedAt: ContinuousClock.Instant = .now,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard case .connected = state else {
            throw RemoteSessionControllerError.notConnected
        }

        let commandGeneration = generation
        pendingCommandCount += 1
        defer { finishPendingCommand() }
        await pauseHealthChecksForCommand()
        let cancellationClosesTransport: Bool
        if recoverCancelledWrite {
            cancellationClosesTransport = await driver.cancellationInvalidatesConnection()
        } else {
            cancellationClosesTransport = false
        }
        try Task.checkCancellation()
        guard generation == commandGeneration, case .connected = state else {
            throw RemoteSessionControllerError.notConnected
        }

        let commandID = UUID()
        let commandSerializer = commandSerializer
        let clock = clock
        let timeout = requestedTimeout ?? configuration.commandTimeout
        let execution = RemoteSessionCommandExecution()
        let task = Task {
            try await RemoteSessionTimeout.run(
                operation: .send,
                timeout: timeout,
                clock: clock
            ) {
                try await commandSerializer.perform {
                    execution.begin()
                    try await operation()
                }
            }
        }
        commandTasks[commandID] = task

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        do {
            try result.get()
            commandTasks[commandID] = nil
            try Task.checkCancellation()
            if generation == commandGeneration, case .connected = state {
                consecutiveHealthFailures = 0
            }
        } catch {
            commandTasks[commandID] = nil
            if error is TVConvenienceError { throw error }
            // A rejected optional request does not establish that ordinary TV controls are unavailable.
            if isConvenienceRequest, error is VizioProtocolError { throw TVConvenienceError.unavailable }
            if optionalFeature, let timeout = error as? RemoteSessionControllerError, case .timedOut = timeout
            {
                throw TVConvenienceError.timedOut
            }
            let wasCancelled = Task.isCancelled || error is CancellationError
            if !wasCancelled,
                error as? TVDriverError == .unsupportedCommand
                    || error as? TVDriverError == .unsupportedTextInput
            {
                // A local capability rejection says nothing about transport health.
                throw error
            }
            if wasCancelled, cancellationClosesTransport, execution.hasBegun, generation == commandGeneration,
                isForeground
            {
                // This driver can close its connection when a write is cancelled.
                // Preserve no connected claim for that generation's uncertain transport.
                transition(to: .offline)
                transitionToPendingReconnectIfAvailable(generation: commandGeneration)
                await disconnectDriverWithinLimit()
                if generation == commandGeneration { scheduleReconnect(generation: commandGeneration) }
            }
            if generation == commandGeneration, !wasCancelled {
                let queuedCommands = Array(commandTasks.values)
                commandTasks.removeAll()
                for queuedCommand in queuedCommands {
                    queuedCommand.cancel()
                }
                let shouldReconnect: Bool
                if let timeoutError = error as? RemoteSessionControllerError {
                    transition(
                        to: .failed(.timedOut(timeoutError.operation)), activityStartedAt: activityStartedAt)
                    shouldReconnect = true
                } else if Self.isOfflineError(error) {
                    transition(to: .offline, activityStartedAt: activityStartedAt)
                    shouldReconnect = true
                } else {
                    transition(to: .failed(.unexpected), activityStartedAt: activityStartedAt)
                    shouldReconnect = false
                }
                if shouldReconnect {
                    transitionToPendingReconnectIfAvailable(generation: commandGeneration)
                    await disconnectDriverWithinLimit()
                    guard generation == commandGeneration else { throw error }
                    scheduleReconnect(generation: commandGeneration)
                }
            }
            if wasCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    func powerOffAndDisconnect(expectedDeviceKey: String) async throws -> Bool {
        let ownerGeneration = generation
        try await send(.powerOff, expectedDeviceKey: expectedDeviceKey)
        try Task.checkCancellation()
        guard generation == ownerGeneration, case .connected(let television) = state,
            television.stableDeviceKey == expectedDeviceKey
        else { throw CancellationError() }
        generation = UUID()
        let teardownGeneration = generation
        targetAddressText = nil
        connectionTarget = nil
        reconnectAttempt = 0
        await cancelInFlightWork()
        guard generation == teardownGeneration else { return false }
        transition(to: .idle)
        await disconnectDriverWithinLimit()
        return generation == teardownGeneration
    }

    func disconnect() async {
        let activityStartedAt = ContinuousClock.now
        generation = UUID()
        targetAddressText = nil
        connectionTarget = nil
        reconnectAttempt = 0
        await cancelInFlightWork()
        transition(to: .idle, activityStartedAt: activityStartedAt)
        await disconnectDriverWithinLimit()
    }

    func forgetPairing(
        for addressText: String,
        reportedDeviceID: String? = nil,
        brand: TVBrand = .samsung
    ) async throws {
        let activityStartedAt = ContinuousClock.now
        try await waitForPairingRemoval()
        try Task.checkCancellation()
        let removalID = UUID()
        pairingRemovalID = removalID

        generation = UUID()
        let removalGeneration = generation
        targetAddressText = nil
        connectionTarget = nil
        reconnectAttempt = 0
        transition(to: .idle, activityStartedAt: activityStartedAt)
        await cancelInFlightWork()
        let didFinishTeardown = await disconnectDriverWithinLimit()
        if Task.isCancelled {
            finishPairingRemoval(id: removalID)
            throw CancellationError()
        }
        guard didFinishTeardown else {
            finishPairingRemoval(id: removalID)
            if generation == removalGeneration {
                transition(to: .failed(.timedOut(.disconnect)), activityStartedAt: activityStartedAt)
            }
            throw RemoteSessionControllerError.timedOut(.disconnect)
        }
        let driver = driver
        let clock = clock
        let timeout = configuration.pairingRemovalTimeout
        let driverTask = Task {
            try await driver.forget(
                addressText: addressText,
                reportedDeviceID: reportedDeviceID,
                brand: brand
            )
        }
        Task { [weak self] in
            _ = await driverTask.result
            await self?.finishPairingRemoval(id: removalID)
        }

        do {
            try await withTaskCancellationHandler {
                try await RemoteSessionTimeout.run(
                    operation: .forgetPairing,
                    timeout: timeout,
                    clock: clock
                ) {
                    try await driverTask.value
                }
            } onCancel: {
                driverTask.cancel()
            }
            finishPairingRemoval(id: removalID)
            try Task.checkCancellation()
        } catch {
            let removalIsStillRunning =
                Task.isCancelled || error is CancellationError
                || error as? RemoteSessionControllerError == .timedOut(.forgetPairing)
            if removalIsStillRunning {
                driverTask.cancel()
            } else {
                finishPairingRemoval(id: removalID)
            }
            if generation == removalGeneration,
                !Task.isCancelled,
                !(error is CancellationError)
            {
                if let timeoutError = error as? RemoteSessionControllerError {
                    transition(
                        to: .failed(.timedOut(timeoutError.operation)), activityStartedAt: activityStartedAt)
                } else {
                    transition(to: .failed(.unexpected), activityStartedAt: activityStartedAt)
                }
            }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Removes one saved credential without changing the active session projection or transport.
    func removePairingCredential(
        for addressText: String,
        reportedDeviceID: String? = nil,
        brand: TVBrand = .samsung
    ) async throws {
        try await waitForPairingRemoval()
        try Task.checkCancellation()
        let removalID = UUID()
        pairingRemovalID = removalID

        let driver = driver
        let clock = clock
        let timeout = configuration.pairingRemovalTimeout
        let driverTask = Task {
            try await driver.removeCredential(
                addressText: addressText,
                reportedDeviceID: reportedDeviceID,
                brand: brand
            )
        }
        Task { [weak self] in
            _ = await driverTask.result
            await self?.finishPairingRemoval(id: removalID)
        }

        do {
            try await withTaskCancellationHandler {
                try await RemoteSessionTimeout.run(
                    operation: .forgetPairing,
                    timeout: timeout,
                    clock: clock
                ) {
                    try await driverTask.value
                }
            } onCancel: {
                driverTask.cancel()
            }
            finishPairingRemoval(id: removalID)
            try Task.checkCancellation()
        } catch {
            let removalIsStillRunning =
                Task.isCancelled || error is CancellationError
                || error as? RemoteSessionControllerError == .timedOut(.forgetPairing)
            if removalIsStillRunning {
                driverTask.cancel()
            } else {
                finishPairingRemoval(id: removalID)
            }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private func waitForPairingRemoval() async throws {
        while pairingRemovalID != nil {
            let clock = clock
            let timeout = configuration.pairingRemovalTimeout
            try await RemoteSessionTimeout.run(
                operation: .forgetPairing,
                timeout: timeout,
                clock: clock
            ) { [weak self] in
                await self?.waitForActivePairingRemoval()
            }
        }
    }

    private func waitForActivePairingRemoval() async {
        let waiterID = UUID()
        let owner = self
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if pairingRemovalID == nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    pairingRemovalWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await owner.cancelPairingRemovalWaiter(id: waiterID)
            }
        }
    }

    private func cancelPairingRemovalWaiter(id: UUID) {
        pairingRemovalWaiters.removeValue(forKey: id)?.resume()
    }

    private func finishPairingRemoval(id: UUID) {
        guard pairingRemovalID == id else { return }
        pairingRemovalID = nil
        let waiters = pairingRemovalWaiters.values
        pairingRemovalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func applicationDidEnterBackground(activityStartedAt: ContinuousClock.Instant = .now) async {
        guard isForeground else { return }
        isForeground = false
        generation = UUID()
        let hasTarget = targetAddressText != nil
        await cancelInFlightWork()
        transition(to: hasTarget ? .offline : .idle, activityStartedAt: activityStartedAt)
        beginDriverTeardownIfNeeded()
    }

    func applicationWillEnterForeground(activityStartedAt: ContinuousClock.Instant = .now) async {
        guard !isForeground else { return }
        isForeground = true
        guard targetAddressText != nil else { return }
        generation = UUID()
        let requestedGeneration = generation
        reconnectAttempt = 0
        transition(to: .reconnecting(attempt: 1), activityStartedAt: activityStartedAt)
        await cancelInFlightWork()
        guard generation == requestedGeneration, isForeground else { return }
        await attemptConnection(
            generation: requestedGeneration, isReconnect: true, activityStartedAt: activityStartedAt)
    }

    func networkReachabilityChanged(isReachable: Bool, activityStartedAt: ContinuousClock.Instant = .now)
        async
    {
        let previous = lastNetworkReachability
        lastNetworkReachability = isReachable
        guard previous != isReachable else { return }

        if !isReachable {
            guard targetAddressText != nil else { return }
            if case .connected = state {
                scheduleNetworkLossConfirmation(generation: generation, activityStartedAt: activityStartedAt)
                return
            }
            generation = UUID()
            await cancelInFlightWork()
            transition(to: .offline, activityStartedAt: activityStartedAt)
            await disconnectDriverWithinLimit()
            return
        }

        guard previous == false, isForeground, targetAddressText != nil else { return }
        let networkLossTask = networkLossTask
        self.networkLossTask = nil
        networkLossTask?.cancel()
        _ = await networkLossTask?.result
        if case .connected = state {
            return
        }
        generation = UUID()
        let requestedGeneration = generation
        reconnectAttempt = 0
        await cancelInFlightWork()
        await attemptConnection(
            generation: requestedGeneration, isReconnect: true, activityStartedAt: activityStartedAt)
    }

    private func attemptConnection(
        generation requestedGeneration: UUID, isReconnect: Bool,
        activityStartedAt: ContinuousClock.Instant = .now
    ) async {
        guard await waitForDriverTeardownWithinLimit() else {
            if generation == requestedGeneration {
                if isReconnect, isForeground, targetAddressText != nil {
                    recoveryAfterDriverTeardownGeneration = requestedGeneration
                }
                transition(to: .failed(.timedOut(.disconnect)), activityStartedAt: activityStartedAt)
                if recoveryAfterDriverTeardownGeneration == requestedGeneration,
                    driverTeardownTask == nil
                {
                    recoveryAfterDriverTeardownGeneration = nil
                    scheduleReconnect(generation: requestedGeneration)
                }
            }
            return
        }
        guard connectionTask == nil,
            generation == requestedGeneration,
            isForeground,
            let targetAddressText
        else { return }

        let attemptNumber = max(1, reconnectAttempt)
        transition(
            to: isReconnect ? .reconnecting(attempt: attemptNumber) : .connecting,
            activityStartedAt: activityStartedAt)

        let id = UUID()
        connectionID = id
        let driver = driver
        let clock = clock
        let connectionTimeout = configuration.connectionTimeout
        let pairingTimeout = configuration.pairingTimeout
        let connectionTarget = connectionTarget
        let task = Task { [weak self] in
            try await RemoteSessionTimeout.runWithExtendableDeadline(
                operation: .connect,
                initialTimeout: connectionTimeout,
                clock: clock
            ) { extendDeadline in
                let onWaitingForApproval: @MainActor @Sendable () async -> Void = {
                    extendDeadline(pairingTimeout)
                    await self?.setPairingState(
                        generation: requestedGeneration,
                        connectionID: id,
                        activityStartedAt: activityStartedAt
                    )
                }
                if let connectionTarget {
                    return try await driver.connect(
                        to: connectionTarget,
                        onWaitingForApproval: onWaitingForApproval
                    )
                }
                return try await driver.connect(
                    addressText: targetAddressText,
                    onWaitingForApproval: onWaitingForApproval
                )
            }
        }
        connectionTask = task

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        do {
            let tv = try result.get()
            guard generation == requestedGeneration, connectionID == id else { return }
            connectionTask = nil
            connectionID = nil
            reconnectTask = nil
            reconnectAttempt = 0
            consecutiveHealthFailures = 0
            // A successful first pairing turns a candidate into a remembered,
            // authenticated identity before any automatic reconnect can occur.
            self.connectionTarget = tv.connectionTarget
            transition(to: .connected(tv), activityStartedAt: activityStartedAt)
            startObservations(generation: requestedGeneration)
            startHealthChecks(generation: requestedGeneration)
        } catch {
            guard generation == requestedGeneration, connectionID == id else { return }
            connectionTask = nil
            connectionID = nil
            if Task.isCancelled || error is CancellationError {
                transition(to: .offline, activityStartedAt: activityStartedAt)
                return
            }
            handleConnectionFailure(
                error, generation: requestedGeneration, activityStartedAt: activityStartedAt)
        }
    }

    private func setPairingState(
        generation requestedGeneration: UUID, connectionID: UUID, activityStartedAt: ContinuousClock.Instant
    ) {
        guard generation == requestedGeneration, self.connectionID == connectionID else { return }
        transition(to: .pairing, activityStartedAt: activityStartedAt)
    }

    private func handleConnectionFailure(
        _ error: Error, generation requestedGeneration: UUID, activityStartedAt: ContinuousClock.Instant
    ) {
        if let timeoutError = error as? RemoteSessionControllerError {
            transition(to: .failed(.timedOut(timeoutError.operation)), activityStartedAt: activityStartedAt)
            scheduleReconnect(generation: requestedGeneration)
        } else if error as? SamsungConnectionError == .pairingTimedOut {
            transition(to: .failed(.timedOut(.connect)), activityStartedAt: activityStartedAt)
            scheduleReconnect(generation: requestedGeneration)
        } else if error as? SonyPairingCoordinatorError == .pairingTimedOut
            || error as? SonyPairingCoordinatorError == .remoteHandshakeTimedOut
        {
            transition(to: .failed(.timedOut(.connect)), activityStartedAt: activityStartedAt)
            scheduleReconnect(generation: requestedGeneration)
        } else if error as? TVDriverError == .savedDeviceIdentityMismatch {
            transition(to: .failed(.savedDeviceIdentityMismatch), activityStartedAt: activityStartedAt)
        } else if error as? SamsungConnectionError == .denied {
            transition(to: .denied, activityStartedAt: activityStartedAt)
        } else if error as? SamsungPairingCoordinatorError == .savedPairingRejected {
            transition(to: .savedPairingRejected, activityStartedAt: activityStartedAt)
        } else if error as? SamsungPairingCoordinatorError == .certificateChanged {
            transition(to: .certificateChanged, activityStartedAt: activityStartedAt)
        } else if error as? SonyPairingCoordinatorError == .certificateChanged
            || error as? SonyTLSChannelError == .certificateChanged
        {
            transition(to: .certificateChanged, activityStartedAt: activityStartedAt)
        } else if error as? SonyPairingCoordinatorError == .pairingRejected,
            connectionTarget?.brand == .sony,
            connectionTarget?.expectedSavedDeviceID != nil
        {
            // A rejected saved credential requires deliberate record-scoped repair.
            // Keep its expected identity out of the fresh-pairing manual fallback.
            transition(to: .savedPairingRejected, activityStartedAt: activityStartedAt)
        } else if error as? SonyPairingCoordinatorError == .invalidPairingCode
            || error as? SonyPairingCoordinatorError == .pairingRejected
            || error as? VizioPairingCoordinatorError == .pinRejected
        {
            transition(to: .denied, activityStartedAt: activityStartedAt)
        } else if error as? VizioPairingCoordinatorError == .savedPairingRejected {
            transition(to: .savedPairingRejected, activityStartedAt: activityStartedAt)
        } else if error as? VizioPairingCoordinatorError == .unrecognizedDeviceInfo {
            transition(to: .failed(.unrecognizedDeviceInfo(.vizio)), activityStartedAt: activityStartedAt)
        } else if error as? VizioPairingCoordinatorError == .certificateChanged
            || error as? VizioPairingCoordinatorError == .deviceIdentityChanged
            || error as? VizioHTTPSClientError == .certificateChanged
        {
            transition(to: .certificateChanged, activityStartedAt: activityStartedAt)
        } else if Self.isUnsupportedError(error) {
            transition(to: .unsupported, activityStartedAt: activityStartedAt)
        } else if Self.isOfflineError(error) {
            transition(to: .offline, activityStartedAt: activityStartedAt)
            scheduleReconnect(generation: requestedGeneration)
        } else {
            transition(to: .failed(.unexpected), activityStartedAt: activityStartedAt)
        }
    }

    /// Keeps automatic retry visible while waiting for the next foreground connection attempt.
    private func scheduleReconnect(generation requestedGeneration: UUID) {
        guard let delay = reconnectDelay else { return }
        guard isForeground,
            reconnectTask == nil,
            lastNetworkReachability != false
        else { return }

        let clock = clock
        reconnectTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
                try Task.checkCancellation()
                await self?.runScheduledReconnect(generation: requestedGeneration)
            } catch {
                await self?.clearReconnectTask(generation: requestedGeneration)
            }
        }
        transition(to: .reconnecting(attempt: max(1, reconnectAttempt + 1)))
    }

    private var reconnectDelay: Duration? {
        if configuration.reconnectDelays.indices.contains(reconnectAttempt) {
            return configuration.reconnectDelays[reconnectAttempt]
        }
        if configuration.repeatsLastReconnectDelay {
            return configuration.reconnectDelays.last
        }
        return nil
    }

    /// Projects automatic recovery before a potentially slow transport teardown begins.
    private func transitionToPendingReconnectIfAvailable(generation requestedGeneration: UUID) {
        guard generation == requestedGeneration,
            reconnectDelay != nil,
            isForeground,
            reconnectTask == nil,
            lastNetworkReachability != false
        else { return }
        transition(to: .reconnecting(attempt: max(1, reconnectAttempt + 1)))
    }

    private func runScheduledReconnect(generation requestedGeneration: UUID) async {
        guard generation == requestedGeneration, isForeground else { return }
        reconnectTask = nil
        reconnectAttempt += 1
        await attemptConnection(generation: requestedGeneration, isReconnect: true)
    }

    private func clearReconnectTask(generation requestedGeneration: UUID) {
        guard generation == requestedGeneration else { return }
        reconnectTask = nil
    }

    private func cancelInFlightWork() async {
        observationTask?.cancel()
        observationTask = nil
        let healthScheduleTask = healthScheduleTask
        self.healthScheduleTask = nil
        healthScheduleTask?.cancel()

        let healthProbeTask = healthProbeTask
        self.healthProbeTask = nil
        healthProbeID = nil
        healthProbeTask?.cancel()

        let networkLossTask = networkLossTask
        self.networkLossTask = nil
        networkLossTask?.cancel()

        consecutiveHealthFailures = 0

        reconnectTask?.cancel()
        reconnectTask = nil

        let connectionTask = connectionTask
        self.connectionTask = nil
        connectionID = nil
        connectionTask?.cancel()

        let commandTasks = Array(commandTasks.values)
        self.commandTasks.removeAll()
        for task in commandTasks {
            task.cancel()
        }

        _ = await connectionTask?.result
        _ = await healthScheduleTask?.result
        _ = await healthProbeTask?.result
        _ = await networkLossTask?.result
        for task in commandTasks {
            _ = await task.result
        }
    }

    private func startHealthChecks(generation requestedGeneration: UUID) {
        scheduleHealthCheck(
            generation: requestedGeneration,
            after: configuration.healthCheckInterval
        )
    }

    private func scheduleHealthCheck(
        generation requestedGeneration: UUID,
        after delay: Duration?
    ) {
        healthScheduleTask?.cancel()
        healthScheduleTask = nil
        guard let delay,
            generation == requestedGeneration,
            isForeground,
            case .connected = state,
            pendingCommandCount == 0,
            commandTasks.isEmpty
        else {
            return
        }
        let clock = clock
        healthScheduleTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
                try Task.checkCancellation()
                await self?.beginHealthCheck(generation: requestedGeneration)
            } catch {
                return
            }
        }
    }

    private func startObservations(generation requestedGeneration: UUID) {
        observationTask?.cancel()
        let driver = driver
        observationTask = Task { [weak self] in
            let observations = await driver.observations()
            for await observation in observations {
                guard !Task.isCancelled else { return }
                await self?.applyObservation(observation, generation: requestedGeneration)
            }
        }
    }

    private func applyObservation(_ observation: TVSessionObservation, generation requestedGeneration: UUID) {
        guard generation == requestedGeneration, isForeground,
            case .connected(let television) = state,
            television.stableDeviceKey == observation.stableDeviceKey
        else { return }
        let updated = television.applying(observation)
        if updated != television { transition(to: .connected(updated)) }
    }

    private func beginHealthCheck(generation requestedGeneration: UUID) async {
        let activityStartedAt = ContinuousClock.now
        guard generation == requestedGeneration, isForeground, case .connected = state else {
            return
        }
        healthScheduleTask = nil
        guard pendingCommandCount == 0, commandTasks.isEmpty else { return }

        let probeID = UUID()
        let driver = driver
        let clock = clock
        let task = Task {
            try await RemoteSessionTimeout.run(
                operation: .healthCheck,
                timeout: configuration.healthCheckTimeout,
                clock: clock
            ) {
                try await driver.checkConnection()
                return try await driver.sessionObservation()
            }
        }
        healthProbeID = probeID
        healthProbeTask = task
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        guard generation == requestedGeneration,
            healthProbeID == probeID,
            isForeground,
            case .connected = state
        else { return }
        healthProbeID = nil
        healthProbeTask = nil

        switch result {
        case .success(let observation):
            consecutiveHealthFailures = 0
            if let observation { applyObservation(observation, generation: requestedGeneration) }
            startHealthChecks(generation: requestedGeneration)
        case .failure(let error):
            if Task.isCancelled || error is CancellationError {
                return
            }
            if Self.isDefinitiveOfflineError(error) {
                Self.logger.notice("Health check confirmed a closed transport")
                await confirmConnectionLoss(
                    generation: requestedGeneration, activityStartedAt: activityStartedAt)
                return
            }
            consecutiveHealthFailures += 1
            if consecutiveHealthFailures < max(1, configuration.healthFailureThreshold) {
                Self.logger.info(
                    "Health check was inconclusive; keeping the session connected pending confirmation"
                )
                scheduleHealthCheck(
                    generation: requestedGeneration,
                    after: configuration.healthCheckRetryDelay
                )
                return
            }
            Self.logger.notice("Repeated health failures confirmed connection loss")
            await confirmConnectionLoss(generation: requestedGeneration, activityStartedAt: activityStartedAt)
        }
    }

    private func confirmConnectionLoss(
        generation requestedGeneration: UUID, activityStartedAt: ContinuousClock.Instant
    ) async {
        guard generation == requestedGeneration, isForeground else { return }
        consecutiveHealthFailures = 0
        healthScheduleTask?.cancel()
        healthScheduleTask = nil
        if healthProbeTask != nil {
            healthProbeTask?.cancel()
            healthProbeTask = nil
            healthProbeID = nil
        }
        transition(to: .offline, activityStartedAt: activityStartedAt)
        transitionToPendingReconnectIfAvailable(generation: requestedGeneration)
        await disconnectDriverWithinLimit()
        guard generation == requestedGeneration, isForeground else { return }
        scheduleReconnect(generation: requestedGeneration)
    }

    private func pauseHealthChecksForCommand() async {
        let healthScheduleTask = healthScheduleTask
        self.healthScheduleTask = nil
        healthScheduleTask?.cancel()

        let healthProbeTask = healthProbeTask
        self.healthProbeTask = nil
        healthProbeID = nil
        healthProbeTask?.cancel()

        _ = await healthScheduleTask?.result
        _ = await healthProbeTask?.result
    }

    private func finishPendingCommand() {
        pendingCommandCount = max(0, pendingCommandCount - 1)
        guard pendingCommandCount == 0, case .connected = state else { return }
        startHealthChecks(generation: generation)
    }

    private func scheduleNetworkLossConfirmation(
        generation requestedGeneration: UUID, activityStartedAt: ContinuousClock.Instant
    ) {
        networkLossTask?.cancel()
        let clock = clock
        let delay = configuration.networkLossGracePeriod
        networkLossTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
                try Task.checkCancellation()
                await self?.confirmNetworkLoss(
                    generation: requestedGeneration, activityStartedAt: activityStartedAt)
            } catch {
                return
            }
        }
    }

    private func confirmNetworkLoss(
        generation requestedGeneration: UUID, activityStartedAt: ContinuousClock.Instant
    ) async {
        networkLossTask = nil
        guard generation == requestedGeneration,
            lastNetworkReachability == false,
            isForeground,
            targetAddressText != nil
        else { return }
        Self.logger.notice("Sustained Wi-Fi path loss confirmed connection loss")
        generation = UUID()
        await cancelInFlightWork()
        transition(to: .offline, activityStartedAt: activityStartedAt)
        await disconnectDriverWithinLimit()
    }

    private static func isDefinitiveOfflineError(_ error: Error) -> Bool {
        if let error = error as? SamsungConnectionError {
            return error == .notConnected
        }
        if let error = error as? SonyTLSChannelError {
            return error == .connectionClosed
        }
        if let error = error as? VizioHTTPSClientError {
            return error == .notConnected
        }
        if let error = error as? MultiBrandSessionDriverError {
            return error == .notConnected
        }
        return false
    }

    @discardableResult
    private func disconnectDriverWithinLimit() async -> Bool {
        beginDriverTeardownIfNeeded()
        return await waitForDriverTeardownWithinLimit()
    }

    /// Starts transport teardown without making a queued foreground event wait for it.
    private func beginDriverTeardownIfNeeded() {
        observationTask?.cancel()
        observationTask = nil
        guard driverTeardownTask == nil else { return }

        let driver = driver
        let teardownID = UUID()
        let task = Task {
            await driver.disconnect()
        }
        driverTeardownID = teardownID
        driverTeardownTask = task
        Task { [weak self] in
            await task.value
            await self?.finishDriverTeardown(id: teardownID)
        }
    }

    private func waitForDriverTeardownWithinLimit() async -> Bool {
        guard let driverTeardownTask, let driverTeardownID else { return true }
        return await waitForDriverTeardownWithinLimit(
            task: driverTeardownTask,
            id: driverTeardownID
        )
    }

    private func waitForDriverTeardownWithinLimit(
        task: Task<Void, Never>,
        id: UUID
    ) async -> Bool {
        let clock = clock
        let timeout = configuration.disconnectTimeout
        do {
            try await RemoteSessionTimeout.run(
                operation: .disconnect,
                timeout: timeout,
                clock: clock
            ) {
                await task.value
            }
            finishDriverTeardown(id: id)
            return true
        } catch {
            task.cancel()
            return false
        }
    }

    private func finishDriverTeardown(id: UUID) {
        guard driverTeardownID == id else { return }
        driverTeardownID = nil
        driverTeardownTask = nil
        let recoveryGeneration = recoveryAfterDriverTeardownGeneration
        recoveryAfterDriverTeardownGeneration = nil
        guard recoveryGeneration == generation,
            isForeground,
            targetAddressText != nil
        else { return }
        scheduleReconnect(generation: generation)
    }

    private func transition(
        to newState: RemoteSessionState, activityStartedAt: ContinuousClock.Instant = .now
    ) {
        let didChangeState = state != newState
        guard
            didChangeState || publishedStateRequestID != stateRequestID
                || publishedStateGeneration != generation || publishedActivityStartedAt != activityStartedAt
        else { return }
        state = newState
        publishedStateRequestID = stateRequestID
        publishedStateGeneration = generation
        publishedStateProducedAt = .now
        publishedActivityStartedAt = activityStartedAt
        if didChangeState {
            for continuation in stateContinuations.values { continuation.yield(newState) }
        }
        let update = currentStateUpdate()
        for continuation in stateUpdateContinuations.values { continuation.yield(update) }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private static func isUnsupportedError(_ error: Error) -> Bool {
        error as? SamsungPairingCoordinatorError == .unsupportedTokenAuthentication
            || error as? SonyPairingCoordinatorError == .unsupportedDevice
            || error as? VizioPairingCoordinatorError == .invalidTarget
            || error as? MultiBrandSessionDriverError == .unsupportedBrand
    }

    private static func isOfflineError(_ error: Error) -> Bool {
        if let error = error as? SamsungConnectionError {
            return error == .unavailable || error == .notConnected
        }
        if let error = error as? SonyTLSChannelError {
            return error == .unavailable || error == .connectionClosed
        }
        if let error = error as? VizioHTTPSClientError {
            return error == .unavailable || error == .notConnected
        }
        if let error = error as? MultiBrandSessionDriverError {
            return error == .notConnected
        }
        return false
    }
}

private enum RemoteSessionTimeout {
    static func run<Value: Sendable>(
        operation: RemoteSessionOperation,
        timeout: Duration,
        clock: any RemoteSessionClock,
        work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = RemoteSessionTimeoutRace<Value>()
        let workTask = Task {
            do {
                race.resolve(.success(try await work()))
            } catch {
                race.resolve(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await clock.sleep(for: timeout)
                try Task.checkCancellation()
                race.resolve(.failure(RemoteSessionControllerError.timedOut(operation)))
            } catch is CancellationError {
                return
            } catch {
                race.resolve(.failure(error))
            }
        }

        defer {
            workTask.cancel()
            timeoutTask.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            workTask.cancel()
            timeoutTask.cancel()
            race.resolve(.failure(CancellationError()))
        }
    }

    static func runWithExtendableDeadline<Value: Sendable>(
        operation: RemoteSessionOperation,
        initialTimeout: Duration,
        clock: any RemoteSessionClock,
        work:
            @escaping @Sendable (
                @escaping @Sendable (Duration) -> Void
            ) async throws -> Value
    ) async throws -> Value {
        let race = RemoteSessionTimeoutRace<Value>()
        let deadline = RemoteSessionResettableDeadline()
        let expire: @Sendable () -> Void = {
            race.resolve(.failure(RemoteSessionControllerError.timedOut(operation)))
        }
        deadline.arm(timeout: initialTimeout, clock: clock, onExpire: expire)

        let workTask = Task {
            do {
                let value = try await work { timeout in
                    deadline.arm(timeout: timeout, clock: clock, onExpire: expire)
                }
                race.resolve(.success(value))
            } catch {
                race.resolve(.failure(error))
            }
        }

        defer {
            workTask.cancel()
            deadline.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            workTask.cancel()
            deadline.cancel()
            race.resolve(.failure(CancellationError()))
        }
    }
}

/// Owns one replaceable deadline without structurally awaiting cancellation-hostile work.
private final class RemoteSessionResettableDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var task: Task<Void, Never>?

    deinit {
        cancel()
    }

    func arm(
        timeout: Duration,
        clock: any RemoteSessionClock,
        onExpire: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        generation &+= 1
        let requestedGeneration = generation
        let previousTask = task
        task = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
                try Task.checkCancellation()
                guard self?.claimExpiry(generation: requestedGeneration) == true else { return }
                onExpire()
            } catch {
                return
            }
        }
        lock.unlock()
        previousTask?.cancel()
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    private func claimExpiry(generation requestedGeneration: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == requestedGeneration else { return false }
        task = nil
        return true
    }
}

/// Resolves a timeout race once without structurally awaiting a task that ignores cancellation.
private final class RemoteSessionTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false

    deinit {}

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}

/// Preserves command submission order while allowing each caller to cancel independently.
private actor RemoteSessionCommandSerializer {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isExecuting = false
    private var waiters: [Waiter] = []

    func perform(_ operation: @Sendable () async throws -> Void) async throws {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isExecuting {
            isExecuting = true
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
        guard acquired else { throw CancellationError() }
    }

    private func release() {
        if waiters.isEmpty {
            isExecuting = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// Distinguishes cancelled FIFO waiters from writes that may have reached the transport.
private final class RemoteSessionCommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        began = true
    }
    var hasBegun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return began
    }
}
