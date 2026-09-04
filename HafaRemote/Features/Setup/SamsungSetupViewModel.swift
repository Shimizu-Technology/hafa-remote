import Foundation
import Observation

@MainActor
@Observable
final class SamsungSetupViewModel {
    enum Status: Equatable {
        case idle
        case checking
        case waitingForApproval
        case connected(PairedSamsungTV)
        case commandSent(PairedSamsungTV)
        case failed(message: String, canForgetPairing: Bool)
    }

    var address = ""
    private(set) var status: Status = .idle

    private let coordinator: any SamsungPairingCoordinating
    private var pairingTask: Task<PairedSamsungTV, Error>?
    private var activePairingID: UUID?
    private var activeConnectionID: UUID?
    private var activeCommandID: UUID?
    private var disconnectTask: Task<Void, Never>?
    private var disconnectTaskID: UUID?

    init(coordinator: (any SamsungPairingCoordinating)? = nil) {
        self.coordinator =
            coordinator
            ?? SamsungPairingCoordinator(
                deviceInfoProvider: SamsungDeviceInfoClient(),
                credentialStore: KeychainSamsungPairingCredentialStore(),
                transport: SamsungCommandTransport()
            )
    }

    isolated deinit {
        pairingTask?.cancel()
    }

    var isBusy: Bool {
        isConnecting || disconnectTask != nil
    }

    var isConnecting: Bool {
        status == .checking || status == .waitingForApproval
    }

    var isControllable: Bool {
        switch status {
        case .connected, .commandSent:
            true
        default:
            false
        }
    }

    func connect() async {
        if let disconnectTask {
            let taskID = disconnectTaskID
            await disconnectTask.value
            clearDisconnectTask(ifMatching: taskID)
        }
        guard !isBusy else { return }
        status = .checking
        activeConnectionID = nil
        activeCommandID = nil
        let pairingID = UUID()
        activePairingID = pairingID
        let address = address
        let task = Task { [coordinator, weak self] in
            try await coordinator.pair(addressText: address) {
                guard self?.activePairingID == pairingID else { return }
                self?.status = .waitingForApproval
            }
        }
        pairingTask = task

        do {
            let tv = try await task.value
            guard activePairingID == pairingID else { return }
            pairingTask = nil
            activePairingID = nil
            activeConnectionID = UUID()
            status = .connected(tv)
        } catch is CancellationError {
            guard activePairingID == pairingID else { return }
            pairingTask = nil
            activePairingID = nil
            status = .idle
        } catch {
            guard activePairingID == pairingID else { return }
            pairingTask = nil
            activePairingID = nil
            status = .failed(
                message: Self.safeMessage(for: error),
                canForgetPairing: (error as? SamsungPairingCoordinatorError)?.canForgetPairing == true
            )
        }
    }

    func sendSelect() async {
        guard let connectionID = activeConnectionID else { return }
        let commandID = UUID()
        activeCommandID = commandID
        let tv: PairedSamsungTV
        switch status {
        case .connected(let connectedTV), .commandSent(let connectedTV):
            tv = connectedTV
        default:
            return
        }
        do {
            try await coordinator.sendSelect()
            guard activeConnectionID == connectionID, activeCommandID == commandID else { return }
            status = .commandSent(tv)
            try? await Task.sleep(for: .seconds(1))
            if activeConnectionID == connectionID,
                activeCommandID == commandID,
                status == .commandSent(tv)
            {
                activeCommandID = nil
                status = .connected(tv)
            }
        } catch {
            guard activeConnectionID == connectionID, activeCommandID == commandID else { return }
            activeConnectionID = nil
            activeCommandID = nil
            status = .failed(message: Self.safeMessage(for: error), canForgetPairing: false)
        }
    }

    func forgetAndRetry() async {
        guard case .failed(_, true) = status else { return }
        do {
            try await coordinator.forget(addressText: address)
            status = .idle
            await connect()
        } catch {
            status = .failed(message: Self.safeMessage(for: error), canForgetPairing: false)
        }
    }

    func disconnect() async {
        if let disconnectTask {
            let taskID = disconnectTaskID
            await disconnectTask.value
            clearDisconnectTask(ifMatching: taskID)
            return
        }

        activeConnectionID = nil
        activeCommandID = nil
        activePairingID = nil
        status = .idle
        let activePairingTask = pairingTask
        pairingTask = nil
        activePairingTask?.cancel()

        let coordinator = coordinator
        let taskID = UUID()
        let task = Task {
            if let activePairingTask {
                _ = await activePairingTask.result
            }
            await coordinator.disconnect()
        }
        disconnectTaskID = taskID
        disconnectTask = task
        await task.value
        clearDisconnectTask(ifMatching: taskID)
    }

    private func clearDisconnectTask(ifMatching taskID: UUID?) {
        guard disconnectTaskID == taskID else { return }
        disconnectTask = nil
        disconnectTaskID = nil
    }

    private static func safeMessage(for error: Error) -> String {
        let description: String? =
            switch error {
            case let error as SamsungConnectionError:
                error.errorDescription
            case let error as SamsungDeviceInfoError:
                error.errorDescription
            case let error as SamsungPairingCoordinatorError:
                error.errorDescription
            case let error as PrivateIPv4AddressError:
                error.errorDescription
            default:
                nil
            }
        return description ?? "Hafa Remote could not complete that request. Try again."
    }
}
