import Foundation

/// Routes one active session while keeping every brand's protocol and credentials isolated.
actor MultiBrandSessionDriver: RemoteSessionDriving {
    nonisolated var brand: TVBrand { .samsung }

    private let samsung: any SamsungPairingCoordinating
    private let sony: any SonyPairingCoordinating
    private let sonyPairingCodeBroker = SonyPairingCodeBroker()
    private var activeBrand: TVBrand?
    private var lastAttemptedBrand: TVBrand?

    init(
        samsung: any SamsungPairingCoordinating,
        sony: any SonyPairingCoordinating
    ) {
        self.samsung = samsung
        self.sony = sony
    }

    nonisolated func supports(_ brand: TVBrand) -> Bool {
        brand == .samsung || brand == .sony
    }

    func connect(
        addressText: String,
        onWaitingForApproval: @escaping @Sendable @MainActor () async -> Void
    ) async throws -> ConnectedTV {
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
            throw MultiBrandSessionDriverError.unsupportedBrand
        }
        activeBrand = target.brand
        return television
    }

    func submitPairingCode(_ code: String) async throws {
        guard lastAttemptedBrand == .sony else {
            throw MultiBrandSessionDriverError.pairingCodeNotExpected
        }
        try await sonyPairingCodeBroker.submit(code)
    }

    func send(_ command: RemoteCommand) async throws {
        switch activeBrand {
        case .samsung:
            try await samsung.send(command)
        case .sony:
            try await sony.send(command)
        case .vizio, .none:
            throw MultiBrandSessionDriverError.notConnected
        }
    }

    func sendText(_ input: RemoteTextInput) async throws {
        switch activeBrand {
        case .samsung:
            try await samsung.sendText(input)
        case .sony:
            try await sony.sendText(input)
        case .vizio, .none:
            throw MultiBrandSessionDriverError.notConnected
        }
    }

    func forget(addressText: String) async throws {
        try await forget(addressText: addressText, reportedDeviceID: nil)
    }

    func forget(addressText: String, reportedDeviceID: String?) async throws {
        await disconnect()
        switch lastAttemptedBrand {
        case .sony:
            guard let reportedDeviceID else {
                throw MultiBrandSessionDriverError.missingStableIdentity
            }
            try await sony.forget(reportedDeviceID: reportedDeviceID)
        case .samsung, .vizio, .none:
            try await samsung.forget(
                addressText: addressText,
                reportedDeviceID: reportedDeviceID
            )
        }
    }

    func disconnect() async {
        activeBrand = nil
        await sonyPairingCodeBroker.cancel()
        await samsung.disconnect()
        await sony.disconnect()
    }
}

actor SonyPairingCodeBroker {
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
            "The Sony TV is not waiting for a pairing code."
        case .pairingCodeAlreadyRequested:
            "A Sony pairing code is already being requested."
        case .missingStableIdentity:
            "Find the Sony TV again before removing its saved pairing."
        }
    }
}

#if DEBUG
    actor SonyPairingUIFixtureDriver: RemoteSessionDriving {
        nonisolated var brand: TVBrand { .sony }
        private let broker = SonyPairingCodeBroker()

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
#endif
