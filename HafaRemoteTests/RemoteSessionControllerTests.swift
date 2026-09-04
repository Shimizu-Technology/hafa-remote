import Foundation
import Testing

@testable import HafaRemote

struct RemoteSessionControllerTests {
    @MainActor
    @Test("The observable store projects actor state for SwiftUI")
    func storeProjectsSessionState() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = MockRemoteSessionDriver(
            outcomes: [.success(tv: tv, announcesPairing: false)]
        )
        let store = RemoteSessionStore(controller: RemoteSessionController(driver: driver))

        await store.connect(to: tv.address.rawValue)
        await waitUntil { @MainActor in store.state == .connected(tv) }

        #expect(store.connectedTV == tv)
        #expect(store.canSendCommands)
    }

    @Test("A first connection publishes connecting, pairing, and connected states")
    func initialConnectionPublishesTruthfulStates() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = MockRemoteSessionDriver(
            outcomes: [.success(tv: tv, announcesPairing: true)]
        )
        let session = RemoteSessionController(driver: driver)
        let states = await session.states()
        let recordedStates = Task {
            var values: [RemoteSessionState] = []
            for await state in states {
                values.append(state)
                if state == .connected(tv) { break }
            }
            return values
        }

        await session.connect(to: tv.address.rawValue)

        #expect(await session.state == .connected(tv))
        #expect(await recordedStates.value == [.idle, .connecting, .pairing, .connected(tv)])
        #expect(await driver.maximumActiveConnectionCount == 1)
    }

    @Test("Denied pairing is distinct from an offline TV")
    func deniedPairingHasDedicatedState() async {
        let driver = MockRemoteSessionDriver(outcomes: [.failure(.denied)])
        let session = RemoteSessionController(driver: driver)

        await session.connect(to: "192.168.10.20")

        #expect(await session.state == .denied)
    }

    @Test("A changed TV certificate requires deliberate pairing repair")
    func changedCertificateHasDedicatedState() async {
        let driver = MockRemoteSessionDriver(outcomes: [.failure(.certificateChanged)])
        let session = RemoteSessionController(driver: driver)

        await session.connect(to: "192.168.10.20")

        #expect(await session.state == .certificateChanged)
    }

    @Test("Unsupported token authentication has a dedicated state")
    func unsupportedTVHasDedicatedState() async {
        let driver = MockRemoteSessionDriver(outcomes: [.failure(.unsupported)])
        let session = RemoteSessionController(driver: driver)

        await session.connect(to: "192.168.10.20")

        #expect(await session.state == .unsupported)
    }

    @Test("Reconnect attempts stop after the configured bound")
    func reconnectAttemptsAreBounded() async {
        let clock = ManualRemoteSessionClock()
        let driver = MockRemoteSessionDriver(
            outcomes: [.failure(.offline), .failure(.offline), .failure(.offline)]
        )
        let configuration = testConfiguration(reconnectDelays: [.seconds(1), .seconds(2)])
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: configuration
        )

        await session.connect(to: "192.168.10.20")
        #expect(await session.state == .offline)

        await resume(clock: clock, duration: .seconds(1))
        await waitUntil { await driver.connectCallCount == 2 }
        await resume(clock: clock, duration: .seconds(2))
        await waitUntil { await driver.connectCallCount == 3 }
        await waitUntil { await session.state == .offline }
        await waitUntil { await clock.pendingSleeps.isEmpty }

        #expect(await session.state == .offline)
        #expect(await driver.connectCallCount == 3)
        #expect(await clock.pendingSleeps.isEmpty)
    }

    @Test("Background pauses retry and foreground reconnects immediately")
    func reconnectIsForegroundOnly() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let clock = ManualRemoteSessionClock()
        let driver = MockRemoteSessionDriver(
            outcomes: [
                .failure(.offline),
                .success(tv: tv, announcesPairing: false),
            ]
        )
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(reconnectDelays: [.seconds(30)])
        )

        await session.connect(to: tv.address.rawValue)
        await session.applicationDidEnterBackground()

        #expect(await session.state == .offline)
        #expect(await driver.connectCallCount == 1)
        await waitUntil { await clock.pendingSleeps.isEmpty }

        await session.applicationWillEnterForeground()

        #expect(await session.state == .connected(tv))
        #expect(await driver.connectCallCount == 2)
    }

    @Test("A meaningful network recovery bypasses the pending delay")
    func networkRecoveryRetriesImmediately() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let clock = ManualRemoteSessionClock()
        let driver = MockRemoteSessionDriver(
            outcomes: [
                .failure(.offline),
                .success(tv: tv, announcesPairing: false),
            ]
        )
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(reconnectDelays: [.seconds(30)])
        )

        await session.networkReachabilityChanged(isReachable: true)
        await session.connect(to: tv.address.rawValue)
        await waitUntil { await clock.pendingSleeps.contains(.seconds(30)) }

        await session.networkReachabilityChanged(isReachable: false)
        await session.networkReachabilityChanged(isReachable: true)

        #expect(await session.state == .connected(tv))
        #expect(await driver.connectCallCount == 2)
        await waitUntil { await clock.pendingSleeps.isEmpty }
    }

    @Test("Switching TVs cancels the old attempt before starting the new one")
    func rapidTVSwitchKeepsOneSession() async throws {
        let firstAddress = try PrivateIPv4Address("192.168.10.20")
        let secondTV = try testTV(address: "192.168.10.21", model: "TEST_MODEL_B")
        let driver = SwitchingRemoteSessionDriver(
            suspendedAddress: firstAddress,
            successfulTV: secondTV
        )
        let session = RemoteSessionController(driver: driver)

        let firstConnection = Task {
            await session.connect(to: firstAddress.rawValue)
        }
        var starts = driver.connectionStarts.makeAsyncIterator()
        _ = await starts.next()

        let secondConnection = Task {
            await session.connect(to: secondTV.address.rawValue)
        }
        await firstConnection.value
        await secondConnection.value

        #expect(await session.state == .connected(secondTV))
        #expect(await driver.cancelledConnectionCount == 1)
        #expect(await driver.maximumActiveConnectionCount == 1)
    }

    @Test("Connection timeout cancels the driver and reports the timed out operation")
    func connectionTimeoutIsEnforced() async {
        let clock = ManualRemoteSessionClock()
        let driver = SuspendedRemoteSessionDriver()
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(
                connectionTimeout: .seconds(5),
                reconnectDelays: []
            )
        )

        let connection = Task {
            await session.connect(to: "192.168.10.20")
        }
        var starts = driver.connectionStarts.makeAsyncIterator()
        _ = await starts.next()
        await resume(clock: clock, duration: .seconds(5))
        await connection.value

        #expect(await session.state == .failed(.timedOut(.connect)))
        #expect(await driver.cancelledConnectionCount == 1)
    }

    @Test("Cancelling the caller cancels the in-flight connection")
    func callerCancellationStopsConnection() async {
        let driver = SuspendedRemoteSessionDriver()
        let session = RemoteSessionController(driver: driver)
        let connection = Task {
            await session.connect(to: "192.168.10.20")
        }
        var starts = driver.connectionStarts.makeAsyncIterator()
        _ = await starts.next()

        connection.cancel()
        await connection.value

        #expect(await session.state == .offline)
        #expect(await driver.cancelledConnectionCount == 1)
    }

    @Test("Command timeout cancels the write and keeps the failure explicit")
    func commandTimeoutIsEnforced() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let clock = ManualRemoteSessionClock()
        let driver = SuspendedCommandRemoteSessionDriver(tv: tv)
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(
                commandTimeout: .seconds(3),
                reconnectDelays: []
            )
        )
        await session.connect(to: tv.address.rawValue)

        let command = Task {
            try await session.send(.select)
        }
        var starts = driver.commandStarts.makeAsyncIterator()
        _ = await starts.next()
        await resume(clock: clock, duration: .seconds(3))

        await #expect(throws: RemoteSessionControllerError.timedOut(.send)) {
            try await command.value
        }
        #expect(await session.state == .failed(.timedOut(.send)))
        #expect(await driver.cancelledCommandCount == 1)
    }

    @Test("Cancelling the caller cancels an in-flight command without losing the session")
    func callerCancellationStopsCommand() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = SuspendedCommandRemoteSessionDriver(tv: tv)
        let session = RemoteSessionController(driver: driver)
        await session.connect(to: tv.address.rawValue)
        let command = Task {
            try await session.send(.select)
        }
        var starts = driver.commandStarts.makeAsyncIterator()
        _ = await starts.next()

        command.cancel()

        await #expect(throws: CancellationError.self) {
            try await command.value
        }
        #expect(await session.state == .connected(tv))
        #expect(await driver.cancelledCommandCount == 1)
    }

    @Test("Disconnect returns at its deadline and cancels stalled cleanup")
    func disconnectTimeoutIsEnforced() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let clock = ManualRemoteSessionClock()
        let driver = SuspendedDisconnectRemoteSessionDriver(tv: tv)
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(
                disconnectTimeout: .seconds(4),
                reconnectDelays: []
            )
        )
        await session.connect(to: tv.address.rawValue)

        let disconnect = Task {
            await session.disconnect()
        }
        var starts = driver.disconnectStarts.makeAsyncIterator()
        _ = await starts.next()
        await resume(clock: clock, duration: .seconds(4))
        await disconnect.value

        #expect(await session.state == .idle)
        #expect(await driver.cancelledDisconnectCount == 1)
    }
}

private enum MockConnectionFailure: Sendable {
    case offline
    case denied
    case certificateChanged
    case unsupported
}

private enum MockConnectionOutcome: Sendable {
    case success(tv: PairedSamsungTV, announcesPairing: Bool)
    case failure(MockConnectionFailure)
}

private actor MockRemoteSessionDriver: RemoteSessionDriving {
    private var outcomes: [MockConnectionOutcome]
    private(set) var connectCallCount = 0
    private(set) var activeConnectionCount = 0
    private(set) var maximumActiveConnectionCount = 0

    init(outcomes: [MockConnectionOutcome]) {
        self.outcomes = outcomes
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        connectCallCount += 1
        guard !outcomes.isEmpty else { throw SamsungConnectionError.unavailable }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case .success(let tv, let announcesPairing):
            if announcesPairing {
                await onWaitingForApproval()
            }
            activeConnectionCount += 1
            maximumActiveConnectionCount = max(maximumActiveConnectionCount, activeConnectionCount)
            return tv
        case .failure(.offline):
            throw SamsungConnectionError.unavailable
        case .failure(.denied):
            throw SamsungConnectionError.denied
        case .failure(.certificateChanged):
            throw SamsungPairingCoordinatorError.certificateChanged
        case .failure(.unsupported):
            throw SamsungPairingCoordinatorError.unsupportedTokenAuthentication
        }
    }

    func send(_ command: RemoteCommand) async throws {}

    func disconnect() {
        activeConnectionCount = max(0, activeConnectionCount - 1)
    }
}

private actor SwitchingRemoteSessionDriver: RemoteSessionDriving {
    nonisolated let connectionStarts: AsyncStream<PrivateIPv4Address>
    private let connectionStartsContinuation: AsyncStream<PrivateIPv4Address>.Continuation
    private let suspendedAddress: PrivateIPv4Address
    private let successfulTV: PairedSamsungTV
    private var suspendedContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var activeConnectionCount = 0
    private(set) var maximumActiveConnectionCount = 0
    private(set) var cancelledConnectionCount = 0

    init(suspendedAddress: PrivateIPv4Address, successfulTV: PairedSamsungTV) {
        self.suspendedAddress = suspendedAddress
        self.successfulTV = successfulTV
        let (stream, continuation) = AsyncStream<PrivateIPv4Address>.makeStream()
        connectionStarts = stream
        connectionStartsContinuation = continuation
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        let address = try PrivateIPv4Address(addressText)
        activeConnectionCount += 1
        maximumActiveConnectionCount = max(maximumActiveConnectionCount, activeConnectionCount)
        connectionStartsContinuation.yield(address)

        if address == suspendedAddress {
            let id = UUID()
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Void, Error>) in
                        suspendedContinuations[id] = continuation
                    }
                } onCancel: { [weak self] in
                    Task {
                        await self?.cancelSuspendedConnection(id)
                    }
                }
            } catch {
                throw error
            }
        }

        activeConnectionCount -= 1
        return successfulTV
    }

    func send(_ command: RemoteCommand) async throws {}

    func disconnect() {}

    private func cancelSuspendedConnection(_ id: UUID) {
        guard let continuation = suspendedContinuations.removeValue(forKey: id) else { return }
        activeConnectionCount -= 1
        cancelledConnectionCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

private actor SuspendedRemoteSessionDriver: RemoteSessionDriving {
    nonisolated let connectionStarts: AsyncStream<Void>
    private let connectionStartsContinuation: AsyncStream<Void>.Continuation
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var cancelledConnectionCount = 0

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        connectionStarts = stream
        connectionStartsContinuation = continuation
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        let id = UUID()
        connectionStartsContinuation.yield()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                continuations[id] = continuation
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancel(id)
            }
        }
        throw SamsungConnectionError.unavailable
    }

    func send(_ command: RemoteCommand) async throws {}

    func disconnect() {}

    private func cancel(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        cancelledConnectionCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

private actor SuspendedCommandRemoteSessionDriver: RemoteSessionDriving {
    nonisolated let commandStarts: AsyncStream<Void>
    private let commandStartsContinuation: AsyncStream<Void>.Continuation
    private let tv: PairedSamsungTV
    private var commandContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var cancelledCommandCount = 0

    init(tv: PairedSamsungTV) {
        self.tv = tv
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        commandStarts = stream
        commandStartsContinuation = continuation
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        tv
    }

    func send(_ command: RemoteCommand) async throws {
        let id = UUID()
        commandStartsContinuation.yield()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                commandContinuations[id] = continuation
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancelCommand(id)
            }
        }
    }

    func disconnect() {}

    private func cancelCommand(_ id: UUID) {
        guard let continuation = commandContinuations.removeValue(forKey: id) else { return }
        cancelledCommandCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

private actor SuspendedDisconnectRemoteSessionDriver: RemoteSessionDriving {
    nonisolated let disconnectStarts: AsyncStream<Void>
    private let disconnectStartsContinuation: AsyncStream<Void>.Continuation
    private let tv: PairedSamsungTV
    private var hasConnected = false
    private var disconnectContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var cancelledDisconnectCount = 0

    init(tv: PairedSamsungTV) {
        self.tv = tv
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        disconnectStarts = stream
        disconnectStartsContinuation = continuation
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        hasConnected = true
        return tv
    }

    func send(_ command: RemoteCommand) async throws {}

    func disconnect() async {
        guard hasConnected else { return }
        hasConnected = false
        let id = UUID()
        let owner = self
        disconnectStartsContinuation.yield()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                disconnectContinuations[id] = continuation
            }
        } onCancel: {
            Task {
                await owner.cancelDisconnect(id)
            }
        }
    }

    private func cancelDisconnect(_ id: UUID) {
        guard let continuation = disconnectContinuations.removeValue(forKey: id) else { return }
        cancelledDisconnectCount += 1
        continuation.resume()
    }
}

private actor ManualRemoteSessionClock: RemoteSessionClock {
    private struct Sleeper {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var sleepers: [Sleeper] = []

    var pendingSleeps: [Duration] {
        sleepers.map(\.duration)
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(id: id, duration: duration, continuation: continuation))
                }
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancel(id)
            }
        }
    }

    func resumeFirst(matching duration: Duration) -> Bool {
        guard let index = sleepers.firstIndex(where: { $0.duration == duration }) else { return false }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume()
        return true
    }

    private func cancel(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
    }
}

private func testTV(address: String, model: String) throws -> PairedSamsungTV {
    PairedSamsungTV(
        address: try PrivateIPv4Address(address),
        modelName: model,
        firmwareVersion: "1001.2"
    )
}

private func testConfiguration(
    connectionTimeout: Duration = .seconds(10),
    commandTimeout: Duration = .seconds(2),
    disconnectTimeout: Duration = .seconds(1),
    reconnectDelays: [Duration]
) -> RemoteSessionConfiguration {
    RemoteSessionConfiguration(
        connectionTimeout: connectionTimeout,
        commandTimeout: commandTimeout,
        disconnectTimeout: disconnectTimeout,
        reconnectDelays: reconnectDelays
    )
}

private func resume(clock: ManualRemoteSessionClock, duration: Duration) async {
    await waitUntil { await clock.pendingSleeps.contains(duration) }
    #expect(await clock.resumeFirst(matching: duration))
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for deterministic test state.", sourceLocation: sourceLocation)
}
