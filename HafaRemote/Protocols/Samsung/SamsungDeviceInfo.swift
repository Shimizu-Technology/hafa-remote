import Foundation

/// Capability details read from a Samsung TV before pairing.
/// The optional MAC is protected local metadata and must never be logged.
struct SamsungDeviceInfo: Equatable, Sendable {
    let reportedDeviceID: String
    let modelName: String
    let firmwareVersion: String?
    let supportsTokenAuthentication: Bool
    let macAddress: SamsungMACAddress?

    init(
        reportedDeviceID: String,
        modelName: String,
        firmwareVersion: String?,
        supportsTokenAuthentication: Bool,
        macAddress: SamsungMACAddress? = nil
    ) {
        self.reportedDeviceID = reportedDeviceID
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.supportsTokenAuthentication = supportsTokenAuthentication
        self.macAddress = macAddress
    }
}

protocol SamsungDeviceInfoProviding: Sendable {
    func fetchDeviceInfo(at address: PrivateIPv4Address) async throws -> SamsungDeviceInfo
}

/// Reads the reviewed pairing and wake fields from the television's local endpoint.
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
        let reportedDeviceID =
            envelope.device.id?.nonemptyTrimmed ?? envelope.device.duid?.nonemptyTrimmed
        guard !modelName.isEmpty, let reportedDeviceID else {
            throw SamsungDeviceInfoError.invalidResponse
        }

        let networkType = envelope.device.networkType?.nonemptyTrimmed?.lowercased()
        let usesWirelessNetwork =
            networkType == nil
            || networkType == "wireless"
            || networkType == "wifi"
            || networkType == "wi-fi"
        let macAddress =
            usesWirelessNetwork
            ? envelope.device.wifiMac?.nonemptyTrimmed.flatMap { try? SamsungMACAddress($0) }
            : nil

        return SamsungDeviceInfo(
            reportedDeviceID: reportedDeviceID,
            modelName: modelName,
            firmwareVersion: envelope.device.firmwareVersion?.nonemptyTrimmed,
            supportsTokenAuthentication: envelope.device.tokenAuthSupport?.lowercased() == "true",
            macAddress: macAddress
        )
    }
}

private struct SamsungDeviceInfoEnvelope: Decodable {
    let device: Device

    struct Device: Decodable {
        let id: String?
        let duid: String?
        let modelName: String
        let firmwareVersion: String?
        let tokenAuthSupport: String?
        let networkType: String?
        let wifiMac: String?

        enum CodingKeys: String, CodingKey {
            case id
            case duid
            case modelName
            case firmwareVersion
            case tokenAuthSupport = "TokenAuthSupport"
            case networkType
            case wifiMac
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
