import Foundation

/// Non-sensitive capability details read from a Samsung TV before pairing.
struct SamsungDeviceInfo: Equatable, Sendable {
    let modelName: String
    let firmwareVersion: String?
    let supportsTokenAuthentication: Bool
}

protocol SamsungDeviceInfoProviding: Sendable {
    func fetchDeviceInfo(at address: PrivateIPv4Address) async throws -> SamsungDeviceInfo
}

/// Reads only model, firmware, and token-auth support from the television's local endpoint.
actor SamsungDeviceInfoClient: SamsungDeviceInfoProviding {
    private let session: URLSession
    private let redirectDelegate: SamsungRedirectRejectingDelegate?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 8
            configuration.waitsForConnectivity = false
            let redirectDelegate = SamsungRedirectRejectingDelegate()
            self.redirectDelegate = redirectDelegate
            self.session = URLSession(
                configuration: configuration,
                delegate: redirectDelegate,
                delegateQueue: nil
            )
        }
    }

    func fetchDeviceInfo(at address: PrivateIPv4Address) async throws -> SamsungDeviceInfo {
        guard let url = URL(string: "http://\(address.rawValue):8001/api/v2/") else {
            throw SamsungDeviceInfoError.invalidEndpoint
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                throw SamsungDeviceInfoError.unavailable
            }

            return try SamsungDeviceInfoParser.parse(data)
        } catch let error as SamsungDeviceInfoError {
            throw error
        } catch is DecodingError {
            throw SamsungDeviceInfoError.invalidResponse
        } catch {
            throw SamsungDeviceInfoError.unavailable
        }
    }
}

final class SamsungRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    deinit {}

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum SamsungDeviceInfoParser {
    static func parse(_ data: Data) throws -> SamsungDeviceInfo {
        let envelope: SamsungDeviceInfoEnvelope
        do {
            envelope = try JSONDecoder().decode(SamsungDeviceInfoEnvelope.self, from: data)
        } catch {
            throw SamsungDeviceInfoError.invalidResponse
        }

        let modelName = envelope.device.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw SamsungDeviceInfoError.invalidResponse
        }

        return SamsungDeviceInfo(
            modelName: modelName,
            firmwareVersion: envelope.device.firmwareVersion?.nonemptyTrimmed,
            supportsTokenAuthentication: envelope.device.tokenAuthSupport?.lowercased() == "true"
        )
    }
}

private struct SamsungDeviceInfoEnvelope: Decodable {
    let device: Device

    struct Device: Decodable {
        let modelName: String
        let firmwareVersion: String?
        let tokenAuthSupport: String?

        enum CodingKeys: String, CodingKey {
            case modelName
            case firmwareVersion
            case tokenAuthSupport = "TokenAuthSupport"
        }
    }
}

extension String {
    fileprivate var nonemptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SamsungDeviceInfoError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "That TV address could not be used."
        case .unavailable:
            "Hafa Remote could not reach a Samsung TV at that address. Check the address and Wi-Fi network."
        case .invalidResponse:
            "A device responded, but it did not identify itself as a supported Samsung TV."
        }
    }
}
