import Foundation

/// The command boundary between product features and a television-specific protocol.
protocol TVDriver: Sendable {
    /// Sends one semantic remote action to the active television connection.
    func send(_ command: RemoteCommand) async throws

    /// Ends the active connection and releases its network resources.
    func disconnect() async
}
