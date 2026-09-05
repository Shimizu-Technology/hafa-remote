import Foundation

/// The command boundary between product features and a television-specific protocol.
protocol TVDriver: Sendable {
    /// Sends one semantic remote action to the active television connection.
    func send(_ command: RemoteCommand) async throws

    /// Sends text to the text field currently focused on the television.
    func sendText(_ input: RemoteTextInput) async throws

    /// Ends the active connection and releases its network resources.
    func disconnect() async
}

extension TVDriver {
    func sendText(_ input: RemoteTextInput) async throws {
        throw TVDriverError.unsupportedTextInput
    }
}

/// Validated text that may cross the television protocol boundary.
struct RemoteTextInput: Equatable, Sendable, CustomStringConvertible {
    static let maximumCharacterCount = 256

    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty,
            value.count <= Self.maximumCharacterCount,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw RemoteTextInputError.invalidText
        }
        self.value = value
    }

    var description: String {
        "RemoteTextInput(redacted, characters: \(value.count))"
    }
}

enum RemoteTextInputError: LocalizedError, Equatable, Sendable {
    case invalidText

    var errorDescription: String? {
        "Enter between 1 and \(RemoteTextInput.maximumCharacterCount) characters without control characters."
    }
}

enum TVDriverError: LocalizedError, Equatable, Sendable {
    case unsupportedTextInput

    var errorDescription: String? {
        "This TV connection does not support remote text input."
    }
}
