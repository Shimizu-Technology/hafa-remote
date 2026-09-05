import Foundation

/// Routes one active session while keeping every brand's protocol and credentials isolated.
actor MultiBrandSessionDriver: RemoteSessionDriving {
    nonisolated var brand: TVBrand { .samsung }

    private let samsung: any SamsungPairingCoordinating
    private let sony: any SonyPairingCoordinating
    private let vizio: any VizioPairingCoordinating
    private let sonyPairingCodeBroker = PairingCodeBroker()
    private let vizioPairingCodeBroker = PairingCodeBroker()
    private var activeBrand: TVBrand?
    private var lastAttemptedBrand: TVBrand?

    init(
        samsung: any SamsungPairingCoordinating,
        sony: any SonyPairingCoordinating,
        vizio: any VizioPairingCoordinating
    ) {
        self.samsung = samsung
        self.sony = sony
        self.vizio = vizio
    }

    nonisolated func supports(_ brand: TVBrand) -> Bool {
        brand == .samsung || brand == .sony || brand == .vizio
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
        await sonyPairingCodeBroker.cancel()
        await vizioPairingCodeBroker.cancel()
        lastAttemptedBrand = .samsung
        activeBrand = nil
        let television = try await samsung.pair(
            addressText: addressText,
            onWaitingForApproval: onWaitingForApproval
        )
        activeBrand = .samsung
        return television
    }

    func connect(
        to target: TVConnectionTarget,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
        guard supports(target.brand) else { throw MultiBrandSessionDriverError.unsupportedBrand }
        await sonyPairingCodeBroker.cancel()
        await vizioPairingCodeBroker.cancel()
        lastAttemptedBrand = target.brand
        activeBrand = nil

        let television: ConnectedTV
        switch target.brand {
        case .samsung:
            guard target.controlPort == nil || target.controlPort == 8002 else {
                throw MultiBrandSessionDriverError.unsupportedBrand
            }
            television = try await samsung.pair(
                addressText: target.address.rawValue,
                onWaitingForApproval: onWaitingForApproval
            )
        case .sony:
            let broker = sonyPairingCodeBroker
            await broker.prepare()
            television = try await sony.connect(to: target) {
                await onWaitingForApproval()
                return try await broker.waitForCode()
            }
        case .vizio:
            let broker = vizioPairingCodeBroker
            await broker.prepare()
            television = try await vizio.pair(target: target) { _ in
                await onWaitingForApproval()
                return try await broker.waitForCode()
            }
        }
        activeBrand = target.brand
        return television
    }

    func submitPairingCode(_ code: String) async throws {
        switch lastAttemptedBrand {
        case .sony:
            try await sonyPairingCodeBroker.submit(code)
        case .vizio:
            try await vizioPairingCodeBroker.submit(code)
        case .samsung, .none:
            throw MultiBrandSessionDriverError.pairingCodeNotExpected
        }
    }

    func send(_ command: RemoteCommand) async throws {
        switch activeBrand {
        case .samsung:
            try await samsung.send(command)
        case .sony:
            try await sony.send(command)
        case .vizio:
            try await vizio.send(command)
        case .none:
            throw MultiBrandSessionDriverError.notConnected
        }
    }

    func sendText(_ input: RemoteTextInput) async throws {
        switch activeBrand {
        case .samsung:
            try await samsung.sendText(input)
        case .sony:
            try await sony.sendText(input)
        case .vizio:
            try await vizio.sendText(input)
        case .none:
            throw MultiBrandSessionDriverError.notConnected
        }
    }

    func forget(addressText: String) async throws {
        try await forget(addressText: addressText, reportedDeviceID: nil, brand: .samsung)
    }

    func forget(addressText: String, reportedDeviceID: String?, brand: TVBrand) async throws {
        await disconnect()
        switch brand {
        case .sony:
            guard let reportedDeviceID else {
                throw MultiBrandSessionDriverError.missingStableIdentity
            }
            try await sony.forget(reportedDeviceID: reportedDeviceID)
        case .vizio:
            guard let reportedDeviceID else {
                throw MultiBrandSessionDriverError.missingStableIdentity
            }
            try await vizio.forget(reportedDeviceID: reportedDeviceID)
        case .samsung:
            try await samsung.forget(
                addressText: addressText,
                reportedDeviceID: reportedDeviceID
            )
        }
    }

    func disconnect() async {
        activeBrand = nil
        await sonyPairingCodeBroker.cancel()
        await vizioPairingCodeBroker.cancel()
        await samsung.disconnect()
        await sony.disconnect()
        await vizio.disconnect()
    }
}

actor PairingCodeBroker {
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingCode: String?
    private var isExpectingCode = false

    func prepare() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        pendingCode = nil
        isExpectingCode = true
    }

    func waitForCode() async throws -> String {
        guard isExpectingCode, continuation == nil else {
            throw MultiBrandSessionDriverError.pairingCodeAlreadyRequested
        }
        if let pendingCode {
            self.pendingCode = nil
            isExpectingCode = false
            return pendingCode
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func submit(_ code: String) throws {
        guard isExpectingCode else {
            throw MultiBrandSessionDriverError.pairingCodeNotExpected
        }
        if let continuation {
            self.continuation = nil
            isExpectingCode = false
            continuation.resume(returning: code)
        } else {
            pendingCode = code
        }
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        pendingCode = nil
        isExpectingCode = false
    }
}

enum MultiBrandSessionDriverError: LocalizedError, Equatable, Sendable {
    case unsupportedBrand
    case notConnected
    case pairingCodeNotExpected
    case pairingCodeAlreadyRequested
    case missingStableIdentity

    var errorDescription: String? {
        switch self {
        case .unsupportedBrand:
            "That TV brand is not enabled in this build."
        case .notConnected:
            "Connect to a TV before sending a command."
        case .pairingCodeNotExpected:
            "The TV is not waiting for a pairing code."
        case .pairingCodeAlreadyRequested:
            "A TV pairing code is already being requested."
        case .missingStableIdentity:
            "Find the TV again before removing its saved pairing."
        }
    }
}

#if DEBUG
    actor SonyPairingUIFixtureDriver: RemoteSessionDriving {
        nonisolated var brand: TVBrand { .sony }
        private let broker = PairingCodeBroker()

        func connect(
            addressText: String,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            let address = try PrivateIPv4Address(addressText)
            return try await connect(
                to: TVConnectionTarget(
                    brand: .sony,
                    reportedDeviceID: "synthetic-sony-tv",
                    address: address,
                    controlPort: 6466
                ),
                onWaitingForApproval: onWaitingForApproval
            )
        }

        func connect(
            to target: TVConnectionTarget,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            await broker.prepare()
            await onWaitingForApproval()
            let code = try await broker.waitForCode()
            guard code == "A1B2C3" else {
                throw SonyPairingCoordinatorError.invalidPairingCode
            }
            return ConnectedTV(
                brand: .sony,
                reportedDeviceID: String(repeating: "a", count: 64),
                address: target.address,
                controlPort: 6466,
                modelName: "Sony BRAVIA",
                firmwareVersion: "1.0"
            )
        }

        func submitPairingCode(_ code: String) async throws {
            try await broker.submit(code)
        }

        func send(_ command: RemoteCommand) {}
        func forget(addressText: String) {}

        func disconnect() async {
            await broker.cancel()
        }
    }

    actor VizioPairingUIFixtureDriver: RemoteSessionDriving {
        nonisolated var brand: TVBrand { .vizio }
        private let broker = PairingCodeBroker()

        func connect(
            addressText: String,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            let address = try PrivateIPv4Address(addressText)
            return try await connect(
                to: TVConnectionTarget(
                    brand: .vizio,
                    reportedDeviceID: "synthetic-vizio-tv",
                    address: address,
                    controlPort: 7345
                ),
                onWaitingForApproval: onWaitingForApproval
            )
        }

        func connect(
            to target: TVConnectionTarget,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            await broker.prepare()
            await onWaitingForApproval()
            let code = try await broker.waitForCode()
            guard code == "1234" else {
                throw VizioPairingCoordinatorError.pinRejected
            }
            return ConnectedTV(
                brand: .vizio,
                reportedDeviceID: "synthetic-vizio-serial",
                address: target.address,
                controlPort: 7345,
                modelName: "Vizio SmartCast",
                firmwareVersion: "1.0"
            )
        }

        func submitPairingCode(_ code: String) async throws {
            try await broker.submit(code)
        }

        func send(_ command: RemoteCommand) {}
        func forget(addressText: String) {}

        func disconnect() async {
            await broker.cancel()
        }
    }

    actor VizioPairingRepairUIFixtureDriver: RemoteSessionDriving {
        private struct PendingPairing {
            let id: UUID
            let target: TVConnectionTarget
            let continuation: CheckedContinuation<ConnectedTV, Error>
        }

        nonisolated var brand: TVBrand { .vizio }
        private var pendingPairing: PendingPairing?
        func connect(
            addressText: String,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            try await connect(
                to: TVConnectionTarget(
                    brand: .vizio,
                    reportedDeviceID: "synthetic-vizio-serial",
                    address: try PrivateIPv4Address(addressText),
                    controlPort: 7345
                ),
                onWaitingForApproval: onWaitingForApproval
            )
        }

        func connect(
            to target: TVConnectionTarget,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            let id = UUID()
            await onWaitingForApproval()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pendingPairing?.continuation.resume(throwing: CancellationError())
                    pendingPairing = PendingPairing(
                        id: id,
                        target: target,
                        continuation: continuation
                    )
                }
            } onCancel: { [weak self] in
                Task {
                    await self?.cancelPairing(id: id)
                }
            }
        }

        func submitPairingCode(_ code: String) throws {
            guard let pairing = pendingPairing else {
                throw MultiBrandSessionDriverError.pairingCodeNotExpected
            }
            pendingPairing = nil
            guard code == "1234" else {
                pairing.continuation.resume(throwing: VizioPairingCoordinatorError.pinRejected)
                return
            }
            pairing.continuation.resume(
                returning: ConnectedTV(
                    brand: .vizio,
                    reportedDeviceID: pairing.target.reportedDeviceID,
                    address: pairing.target.address,
                    controlPort: pairing.target.controlPort,
                    modelName: "Vizio SmartCast",
                    firmwareVersion: "1.0"
                )
            )
        }

        func send(_ command: RemoteCommand) {}
        func forget(addressText: String) {}

        func disconnect() {
            pendingPairing?.continuation.resume(throwing: CancellationError())
            pendingPairing = nil
        }

        private func cancelPairing(id: UUID) {
            guard pendingPairing?.id == id else { return }
            pendingPairing?.continuation.resume(throwing: CancellationError())
            pendingPairing = nil
        }
    }

    actor SavedTVSwitchingUIFixtureDriver: RemoteSessionDriving {
        nonisolated var brand: TVBrand { .samsung }

        nonisolated func supports(_ brand: TVBrand) -> Bool {
            true
        }

        func connect(
            addressText: String,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            let address = try PrivateIPv4Address(addressText)
            return ConnectedTV(
                reportedDeviceID: "fixture-samsung",
                address: address,
                modelName: "Q70AA",
                firmwareVersion: "1.0"
            )
        }

        func connect(
            to target: TVConnectionTarget,
            onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
        ) async throws -> ConnectedTV {
            if target.brand == .sony {
                try await Task.sleep(for: .seconds(3))
            }
            return ConnectedTV(
                brand: target.brand,
                reportedDeviceID: target.reportedDeviceID,
                address: target.address,
                controlPort: target.controlPort,
                modelName: target.brand == .samsung ? "Q70AA" : "Sony BRAVIA",
                firmwareVersion: "1.0"
            )
        }

        func submitPairingCode(_ code: String) async throws {}
        func send(_ command: RemoteCommand) async throws {}
        func sendText(_ input: RemoteTextInput) async throws {}
        func forget(addressText: String) async throws {}
        func disconnect() async {}
    }
#endif
