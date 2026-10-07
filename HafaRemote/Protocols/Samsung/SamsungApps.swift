import Foundation

enum SamsungAppCodec {
    static func request() throws -> URLSessionWebSocketTask.Message {
        try message(["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
    }
    static func launch(_ app: TVAppShortcut) throws -> URLSessionWebSocketTask.Message {
        guard case .samsung(let appID, let deepLink) = app.target, app.target.isValid,
            isAllowed(name: app.name, id: appID)
        else {
            throw TVConvenienceError.unavailable
        }
        return try message([
            "method": "ms.channel.emit",
            "params": [
                "event": "ed.apps.launch", "to": "host",
                "data": [
                    "appId": appID, "action_type": deepLink ? "DEEP_LINK" : "NATIVE_LAUNCH", "metaTag": "",
                ],
            ],
        ])
    }
    static func apps(from message: URLSessionWebSocketTask.Message) throws -> [TVAppShortcut]? {
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: return nil
        }
        guard data.count <= 1_048_576 else { throw TVConvenienceError.invalidResponse }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            envelope["event"] as? String == "ed.installedApp.get"
        else { return nil }
        guard let payload = envelope["data"] as? [String: Any],
            let rows = payload["data"] as? [[String: Any]], rows.count <= 128
        else { throw TVConvenienceError.invalidResponse }
        var result: [TVAppShortcut] = []
        var identifiers: Set<TVAppTarget> = []
        for row in rows {
            guard let name = row["name"] as? String, let id = row["appId"] as? String,
                let type = row["app_type"] as? Int, (0...10).contains(type)
            else { continue }
            guard isAllowed(name: name, id: id) else { continue }
            guard let app = try? TVAppShortcut(name: name, target: .samsung(appID: id, deepLink: type == 2)),
                identifiers.insert(app.target).inserted
            else { continue }
            result.append(app)
        }
        return result
    }
    private static func isAllowed(name: String, id: String) -> Bool {
        let combined = "\(name) \(id)".lowercased()
        return ![
            "factory", "service", "reset", "hospitality", "debug", "developer", "engineering", "diagnostic",
            "internal", "testapp",
        ].contains(where: combined.contains)
    }
    private static func message(_ object: [String: Any]) throws -> URLSessionWebSocketTask.Message {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw TVConvenienceError.invalidResponse }
        return .string(text)
    }
}

/// One bounded query at a time. A failed query closes app discovery until a new socket.
actor SamsungAppListQuery {
    private var continuation: CheckedContinuation<[TVAppShortcut], Error>?
    private var requestID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var acceptsQueries = true
    private var successfulCatalog: [TVAppShortcut]?

    func catalogForLaunch(
        timeout: Duration = .seconds(3), send: @escaping @Sendable () async throws -> Void
    ) async throws -> [TVAppShortcut] {
        try Task.checkCancellation()
        if let successfulCatalog { return successfulCatalog }
        return try await query(timeout: timeout, send: send)
    }

    func query(timeout: Duration = .seconds(3), send: @escaping @Sendable () async throws -> Void)
        async throws -> [TVAppShortcut]
    {
        try Task.checkCancellation()
        guard acceptsQueries else { throw TVConvenienceError.unavailable }
        guard continuation == nil else { throw TVConvenienceError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                requestID = id
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        await self?.finish(id: id, result: .failure(TVConvenienceError.timedOut))
                    } catch {}
                }
                sendTask = Task { [weak self] in
                    do { try await send() } catch { await self?.finish(id: id, result: .failure(error)) }
                }
            }
        } onCancel: {
            Task { await self.finish(id: id, result: .failure(CancellationError())) }
        }
    }
    func receive(_ result: Result<[TVAppShortcut], Error>) {
        guard let requestID else { return }
        finish(id: requestID, result: result)
    }
    func reset() {
        if let requestID { finish(id: requestID, result: .failure(CancellationError())) }
        acceptsQueries = true
        successfulCatalog = nil
    }
    private func finish(id: UUID, result: Result<[TVAppShortcut], Error>) {
        guard requestID == id, let continuation else { return }
        self.continuation = nil
        requestID = nil
        timeoutTask?.cancel()
        sendTask?.cancel()
        timeoutTask = nil
        sendTask = nil
        if case .failure = result { acceptsQueries = false }
        if case .success(let apps) = result { successfulCatalog = apps }
        continuation.resume(with: result)
    }
}
