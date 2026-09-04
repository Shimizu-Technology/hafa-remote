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

    init(coordinator: (any SamsungPairingCoordinating)? = nil) {
        self.coordinator =
            coordinator
            ?? SamsungPairingCoordinator(
                deviceInfoProvider: SamsungDeviceInfoClient(),
                credentialStore: KeychainSamsungPairingCredentialStore(),
                transport: SamsungCommandTransport()
            )
    }

    var isBusy: Bool {
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
        guard !isBusy else { return }
        status = .checking
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
        let tv: PairedSamsungTV
        switch status {
        case .connected(let connectedTV), .commandSent(let connectedTV):
            tv = connectedTV
        default:
            return
        }
        do {
            try await coordinator.sendSelect()
            status = .commandSent(tv)
            try? await Task.sleep(for: .seconds(1))
            if status == .commandSent(tv) {
                status = .connected(tv)
            }
        } catch {
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
        activePairingID = nil
        let task = pairingTask
        pairingTask = nil
        task?.cancel()
        if let task {
            _ = await task.result
        }
        await coordinator.disconnect()
        status = .idle
    }

    private static func safeMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
            let description = localizedError.errorDescription
        {
            return description
        }
        return "Hafa Remote could not complete that request. Try again."
    }
}
