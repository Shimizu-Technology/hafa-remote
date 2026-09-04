import Foundation
import Testing

@testable import HafaRemote

struct PrivateIPv4AddressTests {
    @Test(
        "Accepts canonical private and link-local addresses",
        arguments: ["10.0.0.8", "172.16.5.4", "172.31.255.254", "192.168.1.25", "169.254.10.20"]
    )
    func acceptsPrivateAddress(_ value: String) throws {
        #expect(try PrivateIPv4Address(value).rawValue == value)
    }

    @Test(
        "Rejects malformed and ambiguous addresses",
        arguments: ["192.168.1", "192.168.001.25", "192.168.1.256", ""]
    )
    func rejectsMalformedAddress(_ value: String) {
        #expect(throws: PrivateIPv4AddressError.invalid) {
            try PrivateIPv4Address(value)
        }
    }

    @Test(
        "Rejects addresses outside private and link-local ranges",
        arguments: ["8.8.8.8", "172.15.255.255", "172.32.0.1"]
    )
    func rejectsPublicAddress(_ value: String) {
        #expect(throws: PrivateIPv4AddressError.notPrivate) {
            try PrivateIPv4Address(value)
        }
    }

    @Test("Decoded addresses pass through private-network validation")
    func validatesDecodedAddress() {
        let publicAddress = Data(#"{"rawValue":"8.8.8.8"}"#.utf8)
        #expect(throws: PrivateIPv4AddressError.notPrivate) {
            try JSONDecoder().decode(PrivateIPv4Address.self, from: publicAddress)
        }
    }

    @Test("String descriptions never expose the address")
    func redactsDescription() throws {
        let addressText = "192.168.10.20"
        let address = try PrivateIPv4Address(addressText)

        #expect(!String(describing: address).contains(addressText))
    }
}
