import Foundation

@MainActor
final class CompositeTVDiscoveryBackend: TVDiscoveryBackend {
    private enum TerminalState {
        case finished
        case permissionDenied
        case failed
    }

    private let backends: [any TVDiscoveryBackend]
    private var terminalStates: [Int: TerminalState] = [:]
    private var scanGeneration = UUID()
    private var eventHandler: (@MainActor @Sendable (TVDiscoveryBackendEvent) -> Void)?

    deinit {}

    init(backends: [any TVDiscoveryBackend]) {
        precondition(!backends.isEmpty)
        self.backends = backends
    }

    func start(
        eventHandler: @escaping @MainActor @Sendable (TVDiscoveryBackendEvent) -> Void
    ) {
        stop()
        terminalStates = [:]
        self.eventHandler = eventHandler
        let generation = scanGeneration
        for (index, backend) in backends.enumerated() {
            guard scanGeneration == generation else { break }
            backend.start { [weak self] event in
                self?.receive(event, from: index, generation: generation)
            }
        }
    }

    func stop() {
        scanGeneration = UUID()
        eventHandler = nil
        for backend in backends { backend.stop() }
        terminalStates = [:]
        eventHandler = nil
    }

    private func receive(_ event: TVDiscoveryBackendEvent, from index: Int, generation: UUID) {
        guard scanGeneration == generation, eventHandler != nil else { return }
        switch event {
        case .found:
            eventHandler?(event)
        case .finished:
            terminalStates[index] = .finished
            publishTerminalStateIfNeeded()
        case .permissionDenied:
            terminalStates[index] = .permissionDenied
            publishTerminalStateIfNeeded()
        case .failed:
            terminalStates[index] = .failed
            publishTerminalStateIfNeeded()
        }
    }

    private func publishTerminalStateIfNeeded() {
        guard terminalStates.count == backends.count else { return }
        let handler = eventHandler
        let result: TVDiscoveryBackendEvent
        if terminalStates.values.contains(where: { state in
            if case .permissionDenied = state { return true }
            return false
        }) {
            result = .permissionDenied
        } else if terminalStates.values.allSatisfy({ state in
            if case .finished = state { return true }
            return false
        }) {
            result = .finished
        } else {
            result = .failed
        }
        stop()
        handler?(result)
    }
}
