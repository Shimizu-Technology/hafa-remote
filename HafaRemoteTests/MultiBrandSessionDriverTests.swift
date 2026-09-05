import Foundation
import Testing

@testable import HafaRemote

struct MultiBrandSessionDriverTests {
    @Test("Sony selection requests a code and routes commands only to Sony")
    @MainActor
    func routesSonyPairingAndCommands() async throws {
        let samsung = MultiBrandSamsungFixture()
        let sony = MultiBrandSonyFixture()
        let vizio = MultiBrandVizioFixture()
        let driver = MultiBrandSessionDriver(samsung: samsung, sony: sony, vizio: vizio)
        let target = TVConnectionTarget(
            brand: .sony,
            reportedDeviceID: "synthetic-candidate",
            address: try PrivateIPv4Address("192.168.10.50"),
            controlPort: 6466
        )
        let requestSignal = PairingRequestSignal()
        let connection = Task {
            try await driver.connect(to: target) {
                await requestSignal.signal()
            }
        }

        try await requestSignal.wait()
        try await driver.submitPairingCode("A1B2C3")
        let television = try await connection.value
        try await driver.send(.volumeUp)

        #expect(television.brand == .sony)
        #expect(await sony.receivedCode == "A1B2C3")
        #expect(await sony.commands == [.volumeUp])
        #expect(await samsung.commands.isEmpty)
        #expect(await vizio.commands.isEmpty)
    }

    @Test("A manual Samsung connection cancels a pending Sony code request")
    @MainActor
    func manualSamsungConnectionCancelsSonyPairing() async throws {
        let samsung = MultiBrandSamsungFixture()
        let sony = MultiBrandSonyFixture()
        let vizio = MultiBrandVizioFixture()
        let driver = MultiBrandSessionDriver(samsung: samsung, sony: sony, vizio: vizio)
        let sonyTarget = TVConnectionTarget(
            brand: .sony,
            reportedDeviceID: "synthetic-sony",
            address: try PrivateIPv4Address("192.168.10.50"),
            controlPort: 6466
        )
        let requestSignal = PairingRequestSignal()
        let sonyConnection = Task {
            try await driver.connect(to: sonyTarget) {
                await requestSignal.signal()
            }
        }
        try await requestSignal.wait()

        _ = try await driver.connect(addressText: "192.168.10.51") {}

        await #expect(throws: CancellationError.self) {
            try await sonyConnection.value
        }
        await #expect(throws: MultiBrandSessionDriverError.pairingCodeNotExpected) {
            try await driver.submitPairingCode("A1B2C3")
        }
    }

    @Test("Pairing removal routes on the saved TV brand after another connection")
    @MainActor
    func forgetUsesSavedTVBrand() async throws {
        let samsung = MultiBrandSamsungFixture()
        let sony = MultiBrandSonyFixture()
        let vizio = MultiBrandVizioFixture()
        let driver = MultiBrandSessionDriver(samsung: samsung, sony: sony, vizio: vizio)
        let reportedDeviceID = String(repeating: "a", count: 64)
        let sonyTarget = TVConnectionTarget(
            brand: .sony,
            reportedDeviceID: reportedDeviceID,
            address: try PrivateIPv4Address("192.168.10.50"),
            controlPort: 6466
        )
        let requestSignal = PairingRequestSignal()
        let sonyConnection = Task {
            try await driver.connect(to: sonyTarget) {
                await requestSignal.signal()
            }
        }
        try await requestSignal.wait()
        try await driver.submitPairingCode("A1B2C3")
        _ = try await sonyConnection.value
        _ = try await driver.connect(addressText: "192.168.10.51") {}

        try await driver.forget(
            addressText: sonyTarget.address.rawValue,
            reportedDeviceID: reportedDeviceID,
            brand: .sony
        )

        #expect(await sony.forgottenDeviceIDs == [reportedDeviceID])
        #expect(await samsung.forgottenAddresses.isEmpty)
    }

    @Test("Samsung selection never exposes its commands to the Sony driver")
    func routesSamsungCommands() async throws {
        let samsung = MultiBrandSamsungFixture()
        let sony = MultiBrandSonyFixture()
        let vizio = MultiBrandVizioFixture()
        let driver = MultiBrandSessionDriver(samsung: samsung, sony: sony, vizio: vizio)
        let target = TVConnectionTarget(
            brand: .samsung,
            reportedDeviceID: "synthetic-samsung",
            address: try PrivateIPv4Address("192.168.10.51"),
            controlPort: 8002
        )

        _ = try await driver.connect(to: target) {}
        try await driver.send(.home)

        #expect(await samsung.commands == [.home])
        #expect(await sony.commands.isEmpty)
        #expect(await vizio.commands.isEmpty)
    }

    @Test("Vizio selection requests a PIN and routes commands only to Vizio")
    @MainActor
    func routesVizioPairingAndCommands() async throws {
        let samsung = MultiBrandSamsungFixture()
        let sony = MultiBrandSonyFixture()
        let vizio = MultiBrandVizioFixture()
        let driver = MultiBrandSessionDriver(samsung: samsung, sony: sony, vizio: vizio)
        let target = TVConnectionTarget(
            brand: .vizio,
            reportedDeviceID: "synthetic-candidate",
            address: try PrivateIPv4Address("192.168.10.52"),
            controlPort: 7345
        )
        let requestSignal = PairingRequestSignal()
        let connection = Task {
            try await driver.connect(to: target) {
                await requestSignal.signal()
            }
        }

        try await requestSignal.wait()
        try await driver.submitPairingCode("1234")
        let television = try await connection.value
        try await driver.send(.select)

        #expect(television.brand == .vizio)
        #expect(await vizio.receivedPIN == "1234")
        #expect(await vizio.commands == [.select])
        #expect(await samsung.commands.isEmpty)
        #expect(await sony.commands.isEmpty)
    }

    @Test("Vizio pairing removal stays brand-scoped after a Samsung connection")
    @MainActor
    func forgetUsesSavedVizioBrand() async throws {
        let samsung = MultiBrandSamsungFixture()
        let sony = MultiBrandSonyFixture()
        let vizio = MultiBrandVizioFixture()
        let driver = MultiBrandSessionDriver(samsung: samsung, sony: sony, vizio: vizio)
        let target = TVConnectionTarget(
            brand: .vizio,
            reportedDeviceID: "synthetic-vizio-candidate",
            address: try PrivateIPv4Address("192.168.10.52"),
            controlPort: 7345
        )
        let requestSignal = PairingRequestSignal()
        let connection = Task {
            try await driver.connect(to: target) {
                await requestSignal.signal()
            }
        }
        try await requestSignal.wait()
        try await driver.submitPairingCode("1234")
        let television = try await connection.value
        _ = try await driver.connect(addressText: "192.168.10.51") {}

        try await driver.forget(
            addressText: target.address.rawValue,
            reportedDeviceID: television.reportedDeviceID,
            brand: .vizio
        )

        #expect(await vizio.forgottenDeviceIDs == [television.reportedDeviceID])
        #expect(await samsung.forgottenAddresses.isEmpty)
        #expect(await sony.forgottenDeviceIDs.isEmpty)
    }

    @Test("Cancelling a pending Sony code request releases its continuation")
    func cancelsPairingCodeWait() async {
        let broker = PairingCodeBroker()
        await broker.prepare()
        let waiting = Task { try await broker.waitForCode() }
        await Task.yield()

        await broker.cancel()

        do {
            _ = try await waiting.value
            Issue.record("Expected the code wait to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }
}

private actor MultiBrandSamsungFixture: SamsungPairingCoordinating {
    private(set) var commands: [RemoteCommand] = []
    private(set) var forgottenAddresses: [String] = []

    func pair(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
        ConnectedTV(
            brand: .samsung,
            reportedDeviceID: "synthetic-samsung",
            address: try PrivateIPv4Address(addressText),
            controlPort: 8002,
            modelName: "Synthetic Samsung",
            firmwareVersion: nil
        )
    }

    func send(_ command: RemoteCommand) {
        commands.append(command)
    }

    func forget(addressText: String) {
        forgottenAddresses.append(addressText)
    }
    func disconnect() {}
}

private actor MultiBrandSonyFixture: SonyPairingCoordinating {
    private(set) var commands: [RemoteCommand] = []
    private(set) var receivedCode: String?
    private(set) var forgottenDeviceIDs: [String] = []

    func connect(
        to target: TVConnectionTarget,
        requestPairingCode: @escaping SonyPairingCodeProvider
    ) async throws -> ConnectedTV {
        receivedCode = try await requestPairingCode()
        return ConnectedTV(
            brand: .sony,
            reportedDeviceID: String(repeating: "a", count: 64),
            address: target.address,
            controlPort: 6466,
            modelName: "Synthetic Sony",
            firmwareVersion: nil
        )
    }

    func send(_ command: RemoteCommand) {
        commands.append(command)
    }

    func forget(reportedDeviceID: String) {
        forgottenDeviceIDs.append(reportedDeviceID)
    }
    func disconnect() {}
}

private actor PairingRequestSignal {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func signal() {
        continuation.yield()
    }

    func wait() async throws {
        let stream = stream
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw PairingRequestSignalError.closed }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw PairingRequestSignalError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

private enum PairingRequestSignalError: Error {
    case closed
    case timedOut
}

private actor MultiBrandVizioFixture: VizioPairingCoordinating {
    private(set) var commands: [RemoteCommand] = []
    private(set) var receivedPIN: String?
    private(set) var forgottenDeviceIDs: [String] = []

    func pair(
        target: TVConnectionTarget,
        pinProvider: @escaping VizioPINProvider
    ) async throws -> ConnectedTV {
        receivedPIN = try await pinProvider(
            VizioPairingChallenge(challengeType: 1, requestToken: 42)
        )
        return ConnectedTV(
            brand: .vizio,
            reportedDeviceID: "synthetic-vizio-serial",
            address: target.address,
            controlPort: 7345,
            modelName: "Synthetic Vizio",
            firmwareVersion: nil
        )
    }

    func send(_ command: RemoteCommand) {
        commands.append(command)
    }

    func forget(reportedDeviceID: String) {
        forgottenDeviceIDs.append(reportedDeviceID)
    }
    func disconnect() {}
}
