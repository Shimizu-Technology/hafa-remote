import Foundation
import Testing

@testable import HafaRemote

struct MultiBrandSessionDriverTests {
    @Test("Sony selection requests a code and routes commands only to Sony")
    @MainActor
    func routesSonyPairingAndCommands() async throws {
        let samsung = MultiBrandSamsungFixture()
        let sony = MultiBrandSonyFixture()
        let driver = MultiBrandSessionDriver(samsung: samsung, sony: sony)
        let target = TVConnectionTarget(
            brand: .sony,
            reportedDeviceID: "synthetic-candidate",
            address: try PrivateIPv4Address("192.168.10.50"),
            controlPort: 6466
        )
        var didRequestCode = false
        let connection = Task {
            try await driver.connect(to: target) {
                didRequestCode = true
            }
        }

        while !didRequestCode { await Task.yield() }
        try await driver.submitPairingCode("A1B2C3")
        let television = try await connection.value
        try await driver.send(.volumeUp)

        #expect(television.brand == .sony)
        #expect(await sony.receivedCode == "A1B2C3")
        #expect(await sony.commands == [.volumeUp])
        #expect(await samsung.commands.isEmpty)
    }

    @Test("Samsung selection never exposes its commands to the Sony driver")
    func routesSamsungCommands() async throws {
        let samsung = MultiBrandSamsungFixture()
        let sony = MultiBrandSonyFixture()
        let driver = MultiBrandSessionDriver(samsung: samsung, sony: sony)
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
    }

    @Test("Cancelling a pending Sony code request releases its continuation")
    func cancelsPairingCodeWait() async {
        let broker = SonyPairingCodeBroker()
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

    func forget(addressText: String) {}
    func disconnect() {}
}

private actor MultiBrandSonyFixture: SonyPairingCoordinating {
    private(set) var commands: [RemoteCommand] = []
    private(set) var receivedCode: String?

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

    func forget(reportedDeviceID: String) {}
    func disconnect() {}
}
