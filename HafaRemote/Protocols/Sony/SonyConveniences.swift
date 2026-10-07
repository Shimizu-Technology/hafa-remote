import Foundation

struct SonyIMEFocus: Equatable, Sendable {
    private(set) var fieldCounter: UInt64?
    private(set) var imeCounter: UInt64?
    private(set) var countersField: UInt64?
    private var focusedAt: ContinuousClock.Instant?
    private var countersAt: ContinuousClock.Instant?

    mutating func focus(fieldCounter: UInt64?, at now: ContinuousClock.Instant = .now) {
        self.fieldCounter = fieldCounter
        if fieldCounter != countersField {
            imeCounter = nil
            countersField = nil
            countersAt = nil
        }
        focusedAt = fieldCounter == nil ? nil : now
    }
    mutating func counters(ime: UInt64, field: UInt64, at now: ContinuousClock.Instant = .now) {
        imeCounter = ime
        countersField = field
        countersAt = now
    }
    mutating func clear() { self = Self() }
    func snapshot(at now: ContinuousClock.Instant = .now) throws -> (ime: UInt64, field: UInt64) {
        guard let fieldCounter, let imeCounter, countersField == fieldCounter,
            let focusedAt, let countersAt,
            focusedAt.duration(to: now) >= .zero, focusedAt.duration(to: now) < .seconds(15),
            countersAt.duration(to: now) >= .zero, countersAt.duration(to: now) < .seconds(15)
        else { throw TVConvenienceError.textFieldNotFocused }
        return (imeCounter, fieldCounter)
    }
}

enum SonyConvenienceCodec {
    static func launch(_ app: TVAppShortcut) throws -> Data {
        guard case .sony(let link) = app.target else { throw TVConvenienceError.wrongTV }
        return SonyProtobuf.bytesField(90, SonyProtobuf.stringField(1, link.value))
    }
    static func text(_ input: RemoteTextInput, imeCounter: UInt64, fieldCounter: UInt64) throws -> Data {
        guard imeCounter <= UInt64(Int32.max), fieldCounter <= UInt64(Int32.max) else {
            throw TVConvenienceError.invalidResponse
        }
        // Android selection indices count UTF-16 code units, not Swift grapheme clusters.
        let selection = UInt64(max(0, input.value.utf16.count - 1))
        let field =
            SonyProtobuf.varintField(1, selection)
            + SonyProtobuf.varintField(2, selection)
            + SonyProtobuf.stringField(3, input.value)
        let edit = SonyProtobuf.varintField(1, 1) + SonyProtobuf.bytesField(2, field)
        let batch =
            SonyProtobuf.varintField(1, imeCounter)
            + SonyProtobuf.varintField(2, fieldCounter)
            + SonyProtobuf.bytesField(3, edit)
        return SonyProtobuf.bytesField(21, batch)
    }
    static func event(in fields: [SonyProtobufField]) throws -> SonyRemoteEvent? {
        if let batch = fields.first(where: { $0.number == 21 })?.bytes {
            let nested = try SonyProtobuf.fields(in: batch)
            let ime = nested.first(where: { $0.number == 1 })?.varint ?? 0
            let field = nested.first(where: { $0.number == 2 })?.varint ?? 0
            guard ime <= UInt64(Int32.max), field <= UInt64(Int32.max) else {
                throw SonyProtocolCodecError.malformedProtobuf
            }
            return .imeCounters(ime: ime, field: field)
        }
        if let inject = fields.first(where: { $0.number == 20 || $0.number == 22 })?.bytes {
            let nested = try SonyProtobuf.fields(in: inject)
            guard let status = nested.first(where: { $0.number == 2 })?.bytes else { return .imeFocus(nil) }
            let statusFields = try SonyProtobuf.fields(in: status)
            let counter = statusFields.first(where: { $0.number == 1 })?.varint ?? 0
            if statusFields.contains(where: {
                ($0.number == 3 || $0.number == 4) && ($0.varint ?? 0) > UInt64(Int32.max)
            }) {
                return .imeFocus(nil)
            }
            guard counter <= UInt64(Int32.max) else { throw SonyProtocolCodecError.malformedProtobuf }
            // No incoming text, label, package name, or selection value is retained.
            return .imeFocus(counter)
        }
        return nil
    }
}
