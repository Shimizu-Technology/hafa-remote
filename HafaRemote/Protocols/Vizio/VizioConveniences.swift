import Foundation

enum VizioConvenienceCodec {
    static let inputsPath = "/menu_native/dynamic/tv_settings/devices/name_input"
    static let currentInputPath = "/menu_native/dynamic/tv_settings/devices/current_input"

    static func inputs(from data: Data) throws -> [TVInputSource] {
        let envelope = try object(data)
        guard let items = envelope["ITEMS"] as? [[String: Any]], items.count <= 64 else {
            throw TVConvenienceError.invalidResponse
        }
        var seen: Set<String> = []
        return items.compactMap { row in
            guard row["CNAME"] as? String != "current_input", let value = row["NAME"] as? String,
                seen.insert(value).inserted
            else { return nil }
            let metadata = row["VALUE"] as? [String: Any]
            let name = metadata?["NAME"] as? String ?? row["VALUE"] as? String ?? value
            return try? TVInputSource(value: value, name: name)
        }
    }
    static func currentInputHash(from data: Data) throws -> Int {
        let envelope = try object(data)
        guard let items = envelope["ITEMS"] as? [[String: Any]],
            let row = items.first(where: { $0["CNAME"] as? String == "current_input" }),
            let hash = row["HASHVAL"] as? Int, hash >= 0
        else { throw TVConvenienceError.invalidResponse }
        return hash
    }
    static func isCurrentInput(
        _ input: TVInputSource, current data: Data, available: [TVInputSource]
    ) throws -> Bool {
        let envelope = try object(data)
        guard let items = envelope["ITEMS"] as? [[String: Any]],
            let row = items.first(where: { $0["CNAME"] as? String == "current_input" })
        else { throw TVConvenienceError.invalidResponse }
        let metadata = row["VALUE"] as? [String: Any]
        guard
            let value = row["VALUE"] as? String ?? metadata?["NAME"] as? String ?? metadata?["name"]
                as? String,
            RemoteConvenienceValidation.label(value)
        else { return false }
        // Firmware may report a returned identifier or its returned display alias.
        // Ambiguous aliases cannot establish that this particular input is active.
        let matching = available.filter {
            $0.value.caseInsensitiveCompare(value) == .orderedSame
                || $0.name.caseInsensitiveCompare(value) == .orderedSame
        }
        return matching.count == 1 && matching[0].value == input.value
    }
    static func selectInput(_ input: TVInputSource, currentHash: Int) throws -> Data {
        guard currentHash >= 0, RemoteConvenienceValidation.label(input.value) else {
            throw TVConvenienceError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: [
            "REQUEST": "MODIFY", "HASHVAL": currentHash, "VALUE": input.value,
        ])
    }
    static func currentApp(from data: Data) throws -> TVAppShortcut? {
        let envelope = try object(data)
        guard let item = envelope["ITEM"] as? [String: Any] else { throw TVConvenienceError.invalidResponse }
        guard let value = item["VALUE"] as? [String: Any], !value.isEmpty else { return nil }
        guard let id = value["APP_ID"] as? String, let namespace = value["NAME_SPACE"] as? Int,
            value["MESSAGE"] == nil || value["MESSAGE"] is NSNull || value["MESSAGE"] as? String == ""
        else { throw TVConvenienceError.unavailable }
        // Nonempty messages may carry media/casting actions. Those are out of scope.
        return try TVAppShortcut(name: "Saved TV app", target: .vizio(appID: id, namespace: namespace))
    }
    static func launch(_ app: TVAppShortcut) throws -> Data {
        guard case .vizio(let id, let namespace) = app.target, app.target.isValid else {
            throw TVConvenienceError.unavailable
        }
        return try JSONSerialization.data(withJSONObject: [
            "VALUE": ["APP_ID": id, "NAME_SPACE": namespace, "MESSAGE": NSNull()]
        ])
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        try VizioProtocolCodec.requireSuccess(from: data)
        guard data.count <= 1_048_576,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw TVConvenienceError.invalidResponse }
        return object
    }
}
