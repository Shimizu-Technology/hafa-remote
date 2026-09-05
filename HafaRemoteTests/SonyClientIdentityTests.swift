import Foundation
import Security
import Testing

@testable import HafaRemote

struct SonyClientIdentityTests {
    @Test("Identity provisioning reuses valid saved material without mutation")
    func reusesSavedIdentity() throws {
        let trace = IdentityProvisioningTrace()
        let provisioner = SonyClientIdentityProvisioner(
            loadSavedIdentity: {
                trace.record("load")
                return "saved"
            },
            removeNamespacedMaterial: { trace.record("remove") },
            generateIdentity: {
                trace.record("generate")
                return "generated"
            }
        )

        #expect(try provisioner.identity() == "saved")
        #expect(trace.events == ["load"])
    }

    @Test("A certificate without its private key is removed before replacement")
    func replacesStaleCertificate() throws {
        let trace = IdentityProvisioningTrace()
        let provisioner = SonyClientIdentityProvisioner(
            loadSavedIdentity: { () throws -> String? in
                trace.record("load")
                throw SonyClientIdentityError.identityLookupFailed(errSecItemNotFound)
            },
            removeNamespacedMaterial: { trace.record("remove") },
            generateIdentity: {
                trace.record("generate")
                return "replacement"
            }
        )

        #expect(try provisioner.identity() == "replacement")
        #expect(trace.events == ["load", "remove", "generate"])
    }

    @Test("Failed identity generation cleans its namespaced partial material")
    func cleansAfterFailedGeneration() {
        let trace = IdentityProvisioningTrace()
        let provisioner = SonyClientIdentityProvisioner(
            loadSavedIdentity: {
                trace.record("load")
                return Optional<String>.none
            },
            removeNamespacedMaterial: { trace.record("remove") },
            generateIdentity: { () throws -> String in
                trace.record("generate")
                throw SonyClientIdentityError.certificateGenerationFailed
            }
        )

        #expect(throws: SonyClientIdentityError.certificateGenerationFailed) {
            try provisioner.identity()
        }
        #expect(trace.events == ["load", "remove", "generate", "remove"])
    }

    @Test("Key and certificate queries stay inside the Sony namespace")
    func scopesKeychainQueries() throws {
        let namespace = "com.shimizutechnology.hafaremote.tests.sony"
        let scope = SonyClientIdentityKeychainScope(namespace: namespace)
        let keyAttributes = scope.privateKeyCreationAttributes()
        let privateAttributes = try #require(
            keyAttributes[kSecPrivateKeyAttrs as String] as? [String: Any]
        )

        #expect(
            privateAttributes[kSecAttrApplicationTag as String] as? Data
                == Data("\(namespace).key".utf8)
        )
        #expect(
            scope.privateKeyDeleteQuery()[kSecAttrApplicationTag as String] as? Data
                == Data("\(namespace).key".utf8)
        )
        #expect(
            scope.certificateLookupQuery()[kSecAttrLabel as String] as? String
                == "\(namespace).certificate"
        )
        #expect(
            scope.certificateDeleteQuery()[kSecAttrLabel as String] as? String
                == "\(namespace).certificate"
        )
    }

    @Test("A generated Sony client certificate contains its RSA public key")
    func generatesSelfSignedRSAClientCertificate() throws {
        let privateKey = try makeRSAKey()
        let certificate = try SonyClientCertificateFactory.make(
            privateKey: privateKey,
            commonName: "Hafa Remote Test",
            serialNumber: Data(repeating: 7, count: 16),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        let originalKey = try #require(SecKeyCopyPublicKey(privateKey))

        #expect(try externalRepresentation(certificateKey) == externalRepresentation(originalKey))
        #expect(try SonyRSAKeyComponents(certificate: certificate).exponent == Data([1, 0, 1]))
    }

    @Test("The six-character Sony pairing code verifies certificate ownership")
    func verifiesPairingCode() throws {
        let clientCertificate = try makeCertificate(serialByte: 8)
        let serverCertificate = try makeCertificate(serialByte: 9)
        let suffix = Data([0x12, 0x34])
        let displayCode = try SonyPairingSecret.displayCode(
            suffix: suffix,
            clientCertificate: clientCertificate,
            serverCertificate: serverCertificate
        )

        let digest = try SonyPairingSecret.make(
            pairingCode: displayCode.lowercased(),
            clientCertificate: clientCertificate,
            serverCertificate: serverCertificate
        )

        #expect(displayCode.count == 6)
        #expect(digest.count == 32)
        #expect(throws: SonyClientIdentityError.pairingCodeMismatch) {
            try SonyPairingSecret.make(
                pairingCode: "00" + String(displayCode.dropFirst(2)),
                clientCertificate: clientCertificate,
                serverCertificate: serverCertificate
            )
        }
        #expect(throws: SonyClientIdentityError.invalidPairingCode) {
            try SonyPairingSecret.make(
                pairingCode: "12345Z",
                clientCertificate: clientCertificate,
                serverCertificate: serverCertificate
            )
        }
    }

    private func makeCertificate(serialByte: UInt8) throws -> SecCertificate {
        try SonyClientCertificateFactory.make(
            privateKey: makeRSAKey(),
            commonName: "Synthetic TV",
            serialNumber: Data(repeating: serialByte, count: 16),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func makeRSAKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2_048,
            ] as CFDictionary,
            &error
        )
        return try #require(key)
    }

    private func externalRepresentation(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        return try #require(SecKeyCopyExternalRepresentation(key, &error) as Data?)
    }
}

private final class IdentityProvisioningTrace {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}
