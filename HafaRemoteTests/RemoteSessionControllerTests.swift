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
        #expect(store.lastConnectedTV == tv)
        #expect(store.canSendCommands)
    }

    @MainActor
    @Test("The observable store clears its remembered TV on disconnect and forget")
    func storeClearsRememberedTV() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = MockRemoteSessionDriver(
            outcomes: [
                .success(tv: tv, announcesPairing: false),
                .success(tv: tv, announcesPairing: false),
            ]
        )
        let store = RemoteSessionStore(controller: RemoteSessionController(driver: driver))

        await store.connect(to: tv.address.rawValue)
        await waitUntil { @MainActor in store.state == .connected(tv) }
        await store.disconnect()
        await waitUntil { @MainActor in store.state == .idle }
        #expect(store.lastConnectedTV == nil)

        await store.connect(to: tv.address.rawValue)
        await waitUntil { @MainActor in store.state == .connected(tv) }
        try await store.forgetPairing(for: tv.address.rawValue)
        await waitUntil { @MainActor in store.state == .idle }
        #expect(store.lastConnectedTV == nil)
    }

    @MainActor
    @Test("Setup cancellation can close the socket without forgetting the last TV")
    func storeCanRetainLastTVWhileDisconnecting() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = MockRemoteSessionDriver(
            outcomes: [.success(tv: tv, announcesPairing: false)]
        )
        let store = RemoteSessionStore(controller: RemoteSessionController(driver: driver))
        await store.connect(to: tv.address.rawValue)
        await waitUntil { @MainActor in store.state == .connected(tv) }

        await store.disconnect(clearRememberedTV: false)

        #expect(store.state == .idle)
        #expect(store.lastConnectedTV == tv)
        #expect(!store.canSendCommands)
    }

    @Test("Forgetting pairing clears the session before removing its credential")
    func forgetPairingClearsSession() async throws {
        let driver = MockRemoteSessionDriver(outcomes: [.failure(.denied)])
        let session = RemoteSessionController(driver: driver)

        await session.connect(to: "192.168.10.20")
        try await session.forgetPairing(for: "192.168.10.20")

        #expect(await session.state == .idle)
        #expect(await driver.forgottenAddresses == ["192.168.10.20"])
    }

    @Test("Forgetting pairing disables commands before credential deletion completes")
    func forgetPairingClosesCommandBoundaryBeforeDeletion() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = SuspendedForgetRemoteSessionDriver(tv: tv)
        let session = RemoteSessionController(driver: driver)
        await session.connect(to: tv.address.rawValue)
        var starts = driver.forgetStarts.makeAsyncIterator()

        let forgetting = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await starts.next()

        #expect(await session.state == .idle)
        do {
            try await session.send(.select)
            Issue.record("Expected commands to be rejected while pairing is removed")
        } catch {
            #expect(error as? RemoteSessionControllerError == .notConnected)
        }

        await driver.failForget()
        do {
            try await forgetting.value
            Issue.record("Expected credential deletion to fail")
        } catch {
            #expect(error is SyntheticForgetError)
        }
        #expect(await session.state == .failed(.unexpected))
    }

    @Test("A later connection waits for pairing removal to finish")
    func connectionIsSerializedAfterPairingRemoval() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = SuspendedForgetRemoteSessionDriver(tv: tv)
        let session = RemoteSessionController(driver: driver)
        await session.connect(to: tv.address.rawValue)
        var starts = driver.forgetStarts.makeAsyncIterator()

        let forgetting = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await starts.next()
        let reconnecting = Task {
            await session.connect(to: tv.address.rawValue)
        }

        await driver.completeForget()
        try await forgetting.value
        await reconnecting.value
        #expect(await driver.connectCallCount == 2)
        #expect(await driver.callLog == ["connect", "forget-start", "forget-finish", "connect"])
        #expect(await session.state == .connected(tv))
    }

    @Test("Pairing removal excludes connections throughout teardown")
    func pairingRemovalExcludesConnectionsDuringTeardown() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = ControlledPairingRemovalDriver(tv: tv)
        let session = RemoteSessionController(driver: driver)
        await session.connect(to: tv.address.rawValue)
        var disconnectStarts = driver.disconnectStarts.makeAsyncIterator()
        var forgetStarts = driver.forgetStarts.makeAsyncIterator()

        let firstRemoval = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await disconnectStarts.next()
        let reconnecting = Task {
            await session.connect(to: tv.address.rawValue)
        }

        await driver.completeDisconnect()
        _ = await forgetStarts.next()
        #expect(
            await driver.callLog == [
                "connect", "disconnect-start", "disconnect-finish", "forget-start",
            ]
        )
        await driver.completeForget()
        try await firstRemoval.value
        await reconnecting.value

        #expect(
            await driver.callLog == [
                "connect", "disconnect-start", "disconnect-finish", "forget-start", "forget-finish",
                "connect",
            ]
        )
    }

    @Test("Cancelling pairing removal during teardown releases the recovery barrier")
    func cancellationDuringTeardownReleasesPairingRemovalBarrier() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = ControlledPairingRemovalDriver(tv: tv)
        let session = RemoteSessionController(driver: driver)
        await session.connect(to: tv.address.rawValue)
        var disconnectStarts = driver.disconnectStarts.makeAsyncIterator()

        let removal = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await disconnectStarts.next()
        removal.cancel()
        await #expect(throws: CancellationError.self) {
            try await removal.value
        }
        await driver.completeDisconnect()

        await session.connect(to: tv.address.rawValue)
        #expect(await session.state == .connected(tv))
        #expect(
            await driver.callLog == [
                "connect", "disconnect-start", "disconnect-finish", "connect",
            ]
        )
    }

    @Test("Pairing removal never overlaps a timed-out driver teardown")
    func pairingRemovalStopsWhenTeardownTimesOut() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let clock = ManualRemoteSessionClock()
        let driver = ControlledPairingRemovalDriver(tv: tv)
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(
                disconnectTimeout: .seconds(4),
                reconnectDelays: []
            )
        )
        await session.connect(to: tv.address.rawValue)
        var disconnectStarts = driver.disconnectStarts.makeAsyncIterator()

        let removal = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await disconnectStarts.next()
        await resume(clock: clock, duration: .seconds(4))
        await #expect(throws: RemoteSessionControllerError.timedOut(.disconnect)) {
            try await removal.value
        }
        #expect(await driver.callLog == ["connect", "disconnect-start"])

        await driver.completeDisconnect()
        await waitUntil {
            await driver.callLog == ["connect", "disconnect-start", "disconnect-finish"]
        }
        var forgetStarts = driver.forgetStarts.makeAsyncIterator()
        let retry = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await forgetStarts.next()
        await driver.completeForget()
        try await retry.value
    }

    @Test("Repeated pairing removal waits for the first teardown and deletion")
    func repeatedPairingRemovalIsSerialized() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = ControlledPairingRemovalDriver(tv: tv)
        let session = RemoteSessionController(driver: driver)
        await session.connect(to: tv.address.rawValue)
        var disconnectStarts = driver.disconnectStarts.makeAsyncIterator()
        var forgetStarts = driver.forgetStarts.makeAsyncIterator()

        let firstRemoval = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await disconnectStarts.next()
        let secondRemoval = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }

        await driver.completeDisconnect()
        _ = await forgetStarts.next()
        #expect(await driver.callLog.filter { $0 == "forget-start" }.count == 1)
        await driver.completeForget()
        try await firstRemoval.value

        _ = await forgetStarts.next()
        await driver.completeForget()
        try await secondRemoval.value

        #expect(
            await driver.callLog == [
                "connect", "disconnect-start", "disconnect-finish",
                "forget-start", "forget-finish", "forget-start", "forget-finish",
            ]
        )
    }

    @Test("A stalled pairing removal bounds waiters without overlapping destructive work")
    func pairingRemovalTimeoutKeepsDestructiveWorkSerialized() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let clock = ManualRemoteSessionClock()
        let driver = ControlledPairingRemovalDriver(tv: tv)
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(
                pairingRemovalTimeout: .seconds(4),
                reconnectDelays: []
            )
        )
        var forgetStarts = driver.forgetStarts.makeAsyncIterator()

        let forgetting = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await forgetStarts.next()

        await resume(clock: clock, duration: .seconds(4))
        await #expect(throws: RemoteSessionControllerError.timedOut(.forgetPairing)) {
            try await forgetting.value
        }

        let retryingRemoval = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        let reconnecting = Task {
            await session.connect(to: tv.address.rawValue)
        }
        await waitUntil {
            await clock.pendingSleeps.filter { $0 == .seconds(4) }.count == 2
        }
        await resume(clock: clock, duration: .seconds(4))
        await resume(clock: clock, duration: .seconds(4))
        await #expect(throws: RemoteSessionControllerError.timedOut(.forgetPairing)) {
            try await retryingRemoval.value
        }
        await reconnecting.value

        #expect(await session.state == .failed(.timedOut(.forgetPairing)))
        #expect(await driver.callLog == ["forget-start"])
        await driver.completeForget()
        await waitUntil { await driver.callLog == ["forget-start", "forget-finish"] }

        let successfulRetry = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await forgetStarts.next()
        await driver.completeForget()
        try await successfulRetry.value

        await session.connect(to: tv.address.rawValue)
        #expect(await session.state == .connected(tv))
        #expect(
            await driver.callLog == [
                "forget-start", "forget-finish", "forget-start", "forget-finish", "connect",
            ]
        )
    }

    @Test("Cancelling pairing removal releases a waiting connection without stale failure")
    func cancelledPairingRemovalAllowsRecovery() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = SuspendedForgetRemoteSessionDriver(tv: tv)
        let session = RemoteSessionController(driver: driver)
        await session.connect(to: tv.address.rawValue)
        var starts = driver.forgetStarts.makeAsyncIterator()

        let forgetting = Task {
            try await session.forgetPairing(for: tv.address.rawValue)
        }
        _ = await starts.next()
        let reconnecting = Task {
            await session.connect(to: tv.address.rawValue)
        }
        forgetting.cancel()

        await #expect(throws: CancellationError.self) {
            try await forgetting.value
        }
        await reconnecting.value
        #expect(await driver.cancelledForgetCount == 1)
        #expect(await session.state == .connected(tv))
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

    @Test("A rejected saved pairing retains its distinct recovery state")
    func rejectedSavedPairingHasDedicatedState() async {
        let driver = MockRemoteSessionDriver(outcomes: [.failure(.savedPairingRejected)])
        let session = RemoteSessionController(driver: driver)

        await session.connect(to: "192.168.10.20")

        #expect(await session.state == .savedPairingRejected)
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

    @Test("Reconnect followed by disconnect tears down the latest driver session")
    func reconnectThenDisconnectRunsFreshTeardown() async throws {
        let firstTV = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let secondTV = try testTV(address: "192.168.10.21", model: "TEST_MODEL_B")
        let driver = MockRemoteSessionDriver(
            outcomes: [
                .success(tv: firstTV, announcesPairing: false),
                .success(tv: secondTV, announcesPairing: false),
            ]
        )
        let session = RemoteSessionController(driver: driver)

        await session.connect(to: firstTV.address.rawValue)
        await session.connect(to: secondTV.address.rawValue)
        await session.disconnect()

        #expect(await session.state == .idle)
        #expect(await driver.activeConnectionCount == 0)
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

    @Test("Dismissing setup cancels its connection before disconnecting the session")
    func setupDismissalCannotRestoreASuspendedConnection() async {
        let driver = SuspendedRemoteSessionDriver()
        let session = RemoteSessionController(driver: driver)
        let connection = Task {
            await session.connect(to: "192.168.10.20")
        }
        var starts = driver.connectionStarts.makeAsyncIterator()
        _ = await starts.next()

        connection.cancel()
        await session.disconnect()
        await connection.value

        #expect(await session.state == .idle)
        #expect(await driver.cancelledConnectionCount == 1)
    }

    @Test("Replacing then dismissing setup cannot leave the newer connection running")
    func replacementTaskCleanupRemainsOwnershipSpecific() async {
        let driver = SuspendedRemoteSessionDriver()
        let session = RemoteSessionController(driver: driver)
        var starts = driver.connectionStarts.makeAsyncIterator()

        let first = Task { await session.connect(to: "192.168.10.20") }
        _ = await starts.next()
        first.cancel()

        let second = Task { await session.connect(to: "192.168.10.21") }
        _ = await starts.next()
        await first.value
        second.cancel()
        await session.disconnect()
        await second.value

        #expect(await session.state == .idle)
        #expect(await driver.cancelledConnectionCount == 2)
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

    @Test("Concurrent command submissions reach the driver in FIFO order")
    func commandSubmissionsAreSerialized() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let driver = SuspendedCommandRemoteSessionDriver(tv: tv)
        let session = RemoteSessionController(driver: driver)
        await session.connect(to: tv.address.rawValue)
        var starts = driver.commandStarts.makeAsyncIterator()

        let first = Task { try await session.send(.up) }
        _ = await starts.next()
        let second = Task { try await session.send(.down) }

        await driver.completeCommand()
        try await first.value
        _ = await starts.next()
        #expect(await driver.receivedCommands == [.up, .down])
        await driver.completeCommand()
        try await second.value
    }

    @Test("A timed-out command keeps the driver write slot until the write finishes")
    func timedOutCommandCannotOverlapTheNextWrite() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let clock = ManualRemoteSessionClock()
        let driver = StubbornCommandRemoteSessionDriver(tv: tv)
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(
                commandTimeout: .seconds(4),
                reconnectDelays: []
            )
        )
        await session.connect(to: tv.address.rawValue)
        var starts = driver.commandStarts.makeAsyncIterator()

        let first = Task { try await session.send(.up) }
        _ = await starts.next()
        let second = Task { try await session.send(.down) }
        await waitUntil {
            await clock.pendingSleeps.filter { $0 == .seconds(4) }.count == 2
        }

        #expect(await clock.resumeFirst(matching: .seconds(4)))
        await #expect(throws: RemoteSessionControllerError.timedOut(.send)) {
            try await first.value
        }
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        #expect(await driver.receivedCommands == [.up])

        await session.connect(to: tv.address.rawValue)
        let recoveredCommand = Task { try await session.send(.left) }
        await waitUntil { await clock.pendingSleeps.contains(.seconds(4)) }
        #expect(await driver.receivedCommands == [.up])

        await driver.completeCommand()
        _ = await starts.next()
        #expect(await driver.receivedCommands == [.up, .left])
        await driver.completeCommand()
        try await recoveredCommand.value
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

    @Test("A timed out teardown cannot overlap the next connection")
    func delayedTeardownRemainsSerializedBeforeReconnect() async throws {
        let tv = try testTV(address: "192.168.10.20", model: "TEST_MODEL_A")
        let clock = ManualRemoteSessionClock()
        let driver = ControlledPairingRemovalDriver(tv: tv)
        let session = RemoteSessionController(
            driver: driver,
            clock: clock,
            configuration: testConfiguration(
                disconnectTimeout: .seconds(4),
                reconnectDelays: []
            )
        )
        await session.connect(to: tv.address.rawValue)
        var disconnectStarts = driver.disconnectStarts.makeAsyncIterator()

        let reconnect = Task { await session.connect(to: tv.address.rawValue) }
        _ = await disconnectStarts.next()
        await resume(clock: clock, duration: .seconds(4))
        await waitUntil { await clock.pendingSleeps.contains(.seconds(4)) }
        #expect(await driver.callLog == ["connect", "disconnect-start"])

        await driver.completeDisconnect()
        await reconnect.value
        #expect(
            await driver.callLog == [
                "connect", "disconnect-start", "disconnect-finish", "connect",
            ]
        )
    }
}

private enum MockConnectionFailure: Sendable {
    case offline
    case denied
    case savedPairingRejected
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
    private(set) var forgottenAddresses: [String] = []

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
        case .failure(.savedPairingRejected):
            throw SamsungPairingCoordinatorError.savedPairingRejected
        case .failure(.certificateChanged):
            throw SamsungPairingCoordinatorError.certificateChanged
        case .failure(.unsupported):
            throw SamsungPairingCoordinatorError.unsupportedTokenAuthentication
        }
    }

    func send(_ command: RemoteCommand) async throws {}

    func forget(addressText: String) async throws {
        forgottenAddresses.append(addressText)
    }

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

    func forget(addressText: String) async throws {}

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

    func forget(addressText: String) async throws {}

    func disconnect() {}

    private func cancel(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        cancelledConnectionCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

private enum SyntheticForgetError: Error {
    case failed
}

private actor SuspendedForgetRemoteSessionDriver: RemoteSessionDriving {
    nonisolated let forgetStarts: AsyncStream<Void>
    private let forgetStartsContinuation: AsyncStream<Void>.Continuation
    private let tv: PairedSamsungTV
    private var forgetContinuation: CheckedContinuation<Void, Error>?
    private(set) var connectCallCount = 0
    private(set) var cancelledForgetCount = 0
    private(set) var callLog: [String] = []

    init(tv: PairedSamsungTV) {
        self.tv = tv
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        forgetStarts = stream
        forgetStartsContinuation = continuation
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        connectCallCount += 1
        callLog.append("connect")
        return tv
    }

    func send(_ command: RemoteCommand) async throws {}

    func forget(addressText: String) async throws {
        callLog.append("forget-start")
        forgetStartsContinuation.yield()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                forgetContinuation = continuation
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancelForget()
            }
        }
        callLog.append("forget-finish")
    }

    func disconnect() {}

    func failForget() {
        forgetContinuation?.resume(throwing: SyntheticForgetError.failed)
        forgetContinuation = nil
        forgetStartsContinuation.finish()
    }

    func completeForget() {
        forgetContinuation?.resume()
        forgetContinuation = nil
        forgetStartsContinuation.finish()
    }

    private func cancelForget() {
        guard let forgetContinuation else { return }
        self.forgetContinuation = nil
        cancelledForgetCount += 1
        forgetContinuation.resume(throwing: CancellationError())
        forgetStartsContinuation.finish()
    }
}

private actor ControlledPairingRemovalDriver: RemoteSessionDriving {
    nonisolated let disconnectStarts: AsyncStream<Void>
    nonisolated let forgetStarts: AsyncStream<Void>
    private let disconnectStartsContinuation: AsyncStream<Void>.Continuation
    private let forgetStartsContinuation: AsyncStream<Void>.Continuation
    private let tv: PairedSamsungTV
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var forgetContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendDisconnect = true
    private var hasConnected = false
    private(set) var callLog: [String] = []

    init(tv: PairedSamsungTV) {
        self.tv = tv
        (disconnectStarts, disconnectStartsContinuation) = AsyncStream.makeStream()
        (forgetStarts, forgetStartsContinuation) = AsyncStream.makeStream()
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> PairedSamsungTV {
        callLog.append("connect")
        hasConnected = true
        return tv
    }

    func send(_ command: RemoteCommand) async throws {}

    func forget(addressText: String) async throws {
        callLog.append("forget-start")
        forgetStartsContinuation.yield()
        await withCheckedContinuation { continuation in
            forgetContinuation = continuation
        }
        callLog.append("forget-finish")
    }

    func disconnect() async {
        guard hasConnected else { return }
        hasConnected = false
        callLog.append("disconnect-start")
        if shouldSuspendDisconnect {
            shouldSuspendDisconnect = false
            disconnectStartsContinuation.yield()
            await withCheckedContinuation { continuation in
                disconnectContinuation = continuation
            }
        }
        callLog.append("disconnect-finish")
    }

    func completeDisconnect() {
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }

    func completeForget() {
        forgetContinuation?.resume()
        forgetContinuation = nil
    }
}

private actor SuspendedCommandRemoteSessionDriver: RemoteSessionDriving {
    nonisolated let commandStarts: AsyncStream<Void>
    private let commandStartsContinuation: AsyncStream<Void>.Continuation
    private let tv: PairedSamsungTV
    private var commandContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var cancelledCommandCount = 0
    private(set) var receivedCommands: [RemoteCommand] = []

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
        receivedCommands.append(command)
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

    func forget(addressText: String) async throws {}

    func disconnect() {}

    func completeCommand() {
        guard let id = commandContinuations.keys.first,
            let continuation = commandContinuations.removeValue(forKey: id)
        else { return }
        continuation.resume()
    }

    private func cancelCommand(_ id: UUID) {
        guard let continuation = commandContinuations.removeValue(forKey: id) else { return }
        cancelledCommandCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

/// Models a socket write that does not finish immediately when its task is cancelled.
private actor StubbornCommandRemoteSessionDriver: RemoteSessionDriving {
    nonisolated let commandStarts: AsyncStream<Void>
    private let commandStartsContinuation: AsyncStream<Void>.Continuation
    private let tv: PairedSamsungTV
    private var commandContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedCommands: [RemoteCommand] = []

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
        receivedCommands.append(command)
        commandStartsContinuation.yield()
        await withCheckedContinuation { continuation in
            commandContinuations.append(continuation)
        }
    }

    func forget(addressText: String) async throws {}

    func disconnect() {}

    func completeCommand() {
        guard !commandContinuations.isEmpty else { return }
        commandContinuations.removeFirst().resume()
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

    func forget(addressText: String) async throws {}

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
    pairingRemovalTimeout: Duration = .seconds(3),
    reconnectDelays: [Duration]
) -> RemoteSessionConfiguration {
    RemoteSessionConfiguration(
        connectionTimeout: connectionTimeout,
        commandTimeout: commandTimeout,
        disconnectTimeout: disconnectTimeout,
        pairingRemovalTimeout: pairingRemovalTimeout,
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
