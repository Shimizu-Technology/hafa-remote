import Foundation
import Testing

@testable import HafaRemote

/// Foundation tests that hold release metadata to the product's privacy promise.
struct HafaRemoteTests {
    /// Verifies the user-facing name and required platform declarations in the built app.
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
