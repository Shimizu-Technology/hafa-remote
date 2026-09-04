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
        "Rejects public, malformed, and ambiguous addresses",
        arguments: [
            "8.8.8.8", "172.15.255.255", "172.32.0.1", "192.168.1", "192.168.001.25",
            "192.168.1.256", "",
        ]
    )
    func rejectsUnsafeAddress(_ value: String) {
        #expect(throws: (any Error).self) {
            try PrivateIPv4Address(value)
        }
    }
}
