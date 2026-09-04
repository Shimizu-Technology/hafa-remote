import Foundation
import Testing

@testable import HafaRemote

struct HafaRemoteTests {
    @Test("The shipped metadata matches the product's privacy promise")
    func appMetadataMatchesPrivacyPromise() throws {
        let bundle = Bundle.main

        #expect(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Hafa Remote")
        #expect(bundle.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)

        let localNetworkCopy = try #require(
            bundle.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        )
        #expect(localNetworkCopy.contains("Samsung TVs"))
    }
}
