import Foundation

protocol RemoteSessionDriving: TVDriver {
    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV
    func forget(addressText: String) async throws
}

extension SamsungPairingCoordinator: RemoteSessionDriving {
    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        try await pair(
            addressText: addressText,
            onWaitingForApproval: onWaitingForApproval
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
    let commandTimeout: Duration
    let disconnectTimeout: Duration
    let reconnectDelays: [Duration]

    static let production = RemoteSessionConfiguration(
        connectionTimeout: .seconds(12),
        commandTimeout: .seconds(3),
        disconnectTimeout: .seconds(2),
        reconnectDelays: [.milliseconds(250), .seconds(1), .seconds(2)]
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

/// Owns the single driver session, lifecycle cancellation, and bounded reconnect policy.
actor RemoteSessionController {
    private(set) var state: RemoteSessionState = .idle

    private let driver: any RemoteSessionDriving
    private let clock: any RemoteSessionClock
    private let configuration: RemoteSessionConfiguration

    private var isForeground = true
    private var lastNetworkReachability: Bool?
    private var targetAddressText: String?
    private var generation = UUID()
    private var reconnectAttempt = 0

    private var connectionID: UUID?
    private var connectionTask: Task<PairedSamsungTV, Error>?
    private var pairingRemovalID: UUID?
    private var pairingRemovalTask: Task<Void, Error>?
    private var reconnectTask: Task<Void, Never>?
    private var commandTasks: [UUID: Task<Void, Error>] = [:]
    private var stateContinuations: [UUID: AsyncStream<RemoteSessionState>.Continuation] = [:]

    init(
        driver: any RemoteSessionDriving,
        clock: any RemoteSessionClock = ContinuousRemoteSessionClock(),
        configuration: RemoteSessionConfiguration = .production
    ) {
        self.driver = driver
        self.clock = clock
        self.configuration = configuration
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

    func connect(to addressText: String) async {
        await waitForPairingRemoval()
        guard !Task.isCancelled else { return }
        generation = UUID()
        let requestedGeneration = generation
        targetAddressText = addressText
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil

        await cancelInFlightWork()
        await disconnectDriverWithinLimit()
        guard generation == requestedGeneration, isForeground else { return }
        await attemptConnection(generation: requestedGeneration, isReconnect: false)
    }

    func send(_ command: RemoteCommand) async throws {
        guard case .connected = state else {
            throw RemoteSessionControllerError.notConnected
        }

        let commandID = UUID()
        let commandGeneration = generation
        let driver = driver
        let clock = clock
        let timeout = configuration.commandTimeout
        let task = Task {
            try await RemoteSessionTimeout.run(
                operation: .send,
                timeout: timeout,
                clock: clock
            ) {
                try await driver.send(command)
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
        } catch {
            commandTasks[commandID] = nil
            let wasCancelled = Task.isCancelled || error is CancellationError
            if generation == commandGeneration, !wasCancelled {
                let shouldReconnect: Bool
                if let timeoutError = error as? RemoteSessionControllerError {
                    transition(to: .failed(.timedOut(timeoutError.operation)))
                    shouldReconnect = true
                } else if Self.isOfflineError(error) {
                    transition(to: .offline)
                    shouldReconnect = true
                } else {
                    transition(to: .failed(.unexpected))
                    shouldReconnect = false
                }
                if shouldReconnect {
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

    func disconnect() async {
        generation = UUID()
        targetAddressText = nil
        reconnectAttempt = 0
        await cancelInFlightWork()
        transition(to: .idle)
        await disconnectDriverWithinLimit()
    }

    func forgetPairing(for addressText: String) async throws {
        await waitForPairingRemoval()
        try Task.checkCancellation()
        generation = UUID()
        let removalGeneration = generation
        targetAddressText = nil
        reconnectAttempt = 0
        transition(to: .idle)
        await cancelInFlightWork()
        await disconnectDriverWithinLimit()
        let removalID = UUID()
        let driver = driver
        let task = Task {
            try await driver.forget(addressText: addressText)
        }
        pairingRemovalID = removalID
        pairingRemovalTask = task
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        if pairingRemovalID == removalID {
            pairingRemovalID = nil
            pairingRemovalTask = nil
        }
        do {
            try result.get()
            try Task.checkCancellation()
        } catch {
            if generation == removalGeneration,
                !Task.isCancelled,
                !(error is CancellationError)
            {
                transition(to: .failed(.unexpected))
            }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private func waitForPairingRemoval() async {
        guard let pairingRemovalTask else { return }
        _ = await pairingRemovalTask.result
    }

    func applicationDidEnterBackground() async {
        guard isForeground else { return }
        isForeground = false
        generation = UUID()
        let hasTarget = targetAddressText != nil
        await cancelInFlightWork()
        transition(to: hasTarget ? .offline : .idle)
        await disconnectDriverWithinLimit()
    }

    func applicationWillEnterForeground() async {
        guard !isForeground else { return }
        isForeground = true
        guard targetAddressText != nil else { return }
        generation = UUID()
        let requestedGeneration = generation
        reconnectAttempt = 0
        await cancelInFlightWork()
        await attemptConnection(generation: requestedGeneration, isReconnect: true)
    }

    func networkReachabilityChanged(isReachable: Bool) async {
        let previous = lastNetworkReachability
        lastNetworkReachability = isReachable
        guard previous != isReachable else { return }

        if !isReachable {
            guard targetAddressText != nil else { return }
            generation = UUID()
            await cancelInFlightWork()
            transition(to: .offline)
            await disconnectDriverWithinLimit()
            return
        }

        guard previous == false, isForeground, targetAddressText != nil else { return }
        generation = UUID()
        let requestedGeneration = generation
        reconnectAttempt = 0
        await cancelInFlightWork()
        await attemptConnection(generation: requestedGeneration, isReconnect: true)
    }

    private func attemptConnection(generation requestedGeneration: UUID, isReconnect: Bool) async {
        guard connectionTask == nil,
            generation == requestedGeneration,
            isForeground,
            let targetAddressText
        else { return }

        let attemptNumber = max(1, reconnectAttempt)
        transition(to: isReconnect ? .reconnecting(attempt: attemptNumber) : .connecting)

        let id = UUID()
        connectionID = id
        let driver = driver
        let clock = clock
        let timeout = configuration.connectionTimeout
        let task = Task { [weak self] in
            try await RemoteSessionTimeout.run(
                operation: .connect,
                timeout: timeout,
                clock: clock
            ) {
                try await driver.connect(addressText: targetAddressText) {
                    await self?.setPairingState(
                        generation: requestedGeneration,
                        connectionID: id
                    )
                }
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
            transition(to: .connected(tv))
        } catch {
            guard generation == requestedGeneration, connectionID == id else { return }
            connectionTask = nil
            connectionID = nil
            if Task.isCancelled || error is CancellationError {
                transition(to: .offline)
                return
            }
            handleConnectionFailure(error, generation: requestedGeneration)
        }
    }

    private func setPairingState(generation requestedGeneration: UUID, connectionID: UUID) {
        guard generation == requestedGeneration, self.connectionID == connectionID else { return }
        transition(to: .pairing)
    }

    private func handleConnectionFailure(_ error: Error, generation requestedGeneration: UUID) {
        if let timeoutError = error as? RemoteSessionControllerError {
            transition(to: .failed(.timedOut(timeoutError.operation)))
            scheduleReconnect(generation: requestedGeneration)
        } else if error as? SamsungConnectionError == .pairingTimedOut {
            transition(to: .failed(.timedOut(.connect)))
            scheduleReconnect(generation: requestedGeneration)
        } else if error as? SamsungConnectionError == .denied {
            transition(to: .denied)
        } else if error as? SamsungPairingCoordinatorError == .savedPairingRejected {
            transition(to: .savedPairingRejected)
        } else if error as? SamsungPairingCoordinatorError == .certificateChanged {
            transition(to: .certificateChanged)
        } else if Self.isUnsupportedError(error) {
            transition(to: .unsupported)
        } else if Self.isOfflineError(error) {
            transition(to: .offline)
            scheduleReconnect(generation: requestedGeneration)
        } else {
            transition(to: .failed(.unexpected))
        }
    }

    private func scheduleReconnect(generation requestedGeneration: UUID) {
        guard isForeground,
            reconnectTask == nil,
            lastNetworkReachability != false,
            configuration.reconnectDelays.indices.contains(reconnectAttempt)
        else { return }

        let delay = configuration.reconnectDelays[reconnectAttempt]
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
        for task in commandTasks {
            _ = await task.result
        }
    }

    private func disconnectDriverWithinLimit() async {
        let driver = driver
        let clock = clock
        let timeout = configuration.disconnectTimeout
        _ = try? await RemoteSessionTimeout.run(
            operation: .disconnect,
            timeout: timeout,
            clock: clock
        ) {
            await driver.disconnect()
        }
    }

    private func transition(to newState: RemoteSessionState) {
        guard state != newState else { return }
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private static func isUnsupportedError(_ error: Error) -> Bool {
        error as? SamsungPairingCoordinatorError == .unsupportedTokenAuthentication
    }

    private static func isOfflineError(_ error: Error) -> Bool {
        guard let error = error as? SamsungConnectionError else { return false }
        return error == .unavailable || error == .notConnected
    }
}

private enum RemoteSessionTimeout {
    static func run<Value: Sendable>(
        operation: RemoteSessionOperation,
        timeout: Duration,
        clock: any RemoteSessionClock,
        work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw RemoteSessionControllerError.timedOut(operation)
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}
