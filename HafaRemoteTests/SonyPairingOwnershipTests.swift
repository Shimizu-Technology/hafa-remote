import CryptoKit
import Foundation
import Security
import Testing

@testable import HafaRemote

struct SonyPairingOwnershipTests {
    @Test(
        "Production Sony pairing cannot close B after A's held lookup or save",
        arguments: [false, true], [false, true])
    func productionPairingRetainsReplacementChannel(holdSave: Bool, cancelOriginal: Bool) async throws {
        let material = try SyntheticPairingMaterial()
        let store = HeldSonyCredentialStore(peerA: material.peerA, holdSave: holdSave)
        let pairing = PairingFixtureChannel(material: material, isControl: false)
        let control = PairingFixtureChannel(material: material, isControl: true)
        let coordinator = SonyPairingCoordinator(
            identityProvider: { material.identity }, credentialStore: store, pairingChannel: pairing,
            controlChannel: control, keyboardPreference: { _ in true })
        let oldAttempt = Task {
            try await coordinator.connect(to: material.targetA) { material.codeA }
        }
        await store.waitUntilHeld()
        #expect(await pairing.activeLabel == "A")
        if cancelOriginal { oldAttempt.cancel() }
        await coordinator.disconnect()

        let code = HeldSonyPairingCode()
        let replacement = Task {
            try await coordinator.connect(to: material.targetB) {
                await code.wait()
                return material.codeB
            }
        }
        await code.waitUntilRequested()
        #expect(await pairing.activeLabel == "B")
        let disconnects = await pairing.disconnectCount
        await store.releaseHeld()
        await #expect(throws: CancellationError.self) { try await oldAttempt.value }
        #expect(await pairing.disconnectCount == disconnects)
        #expect(await pairing.activeLabel == "B")

        await code.release()
        switch await replacement.result {
        case .success(let television):
            #expect(television.reportedDeviceID == material.credentialB.reportedDeviceID)
            try await coordinator.checkConnection()
            try await coordinator.send(.right)
            #expect(await control.commandCount == 1)
        case .failure:
            Issue.record("Replacement B must complete its real pairing exchange and control handshake")
        }
        #expect(await store.heldLookupCount == (holdSave ? 0 : 1))
        #expect(await store.heldSaveCount == (holdSave ? 1 : 0))
        await coordinator.disconnect()
    }

    @Test("Sony app launch requires new focus and counters before text")
    func launchInvalidatesPreviousIME() async throws {
        try await assertScreenChangeInvalidatesIME(command: nil)
    }

    @Test("Focus received during an app-link write cannot restore the prior screen's IME")
    func inFlightLaunchCannotRenewOldFocus() async throws {
        let channel = PairingFixtureChannel()
        let coordinator = SonyPairingCoordinator(controlChannel: channel, keyboardPreference: { _ in true })
        let television = ConnectedTV(
            brand: .sony, reportedDeviceID: "synthetic-ime-inflight",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.89"),
            modelName: "Synthetic Model", firmwareVersion: nil, powerState: .on)
        try await coordinator.installSyntheticSessionForTesting(television, reportedFeatures: 615)
        await channel.openSyntheticControl()
        await coordinator.focusSyntheticFieldForTesting()
        await channel.holdNextLaunch()
        let launch = Task {
            try await coordinator.convenience(.launch(TVAppShortcut.sonyConfiguredLinks[0]))
        }
        await channel.waitUntilLaunchStarted()
        await coordinator.focusSyntheticFieldForTesting()
        await channel.releaseLaunch()
        _ = try await launch.value
        await #expect(throws: TVConvenienceError.textFieldNotFocused) {
            try await coordinator.sendText(RemoteTextInput("synthetic text"))
        }
        #expect(await channel.textCount == 0)
        await coordinator.focusSyntheticFieldForTesting(imeCounter: 3)
        try await coordinator.sendText(RemoteTextInput("synthetic text"))
        #expect(await channel.textCount == 1)
        await coordinator.disconnect()
    }

    @Test("A revoked attempt is rejected at the real TLS actor before any network start")
    func revokedLeaseCannotEnterTLSActor() async throws {
        let material = try SyntheticPairingMaterial()
        let ownership = SonyTLSChannelOwnership()
        ownership.invalidate()
        let channel = SonyTLSChannel()
        await #expect(throws: CancellationError.self) {
            _ = try await channel.connect(
                address: material.targetA.address, port: 6467, identity: material.identity,
                trustMode: .selectedPairingCandidate, ownership: ownership)
        }
        await #expect(throws: CancellationError.self) { try await channel.send(Data(), ownership: ownership) }
        await #expect(throws: CancellationError.self) { try await channel.receive(ownership: ownership) }
        await #expect(throws: CancellationError.self) {
            try await channel.checkConnection(ownership: ownership)
        }
        await channel.disconnect(ownership: ownership)
        await #expect(throws: SonyTLSChannelError.connectionClosed) { try await channel.checkConnection() }
    }

    @Test(
        "Sony tuner and source actions invalidate old text-field evidence",
        arguments: [
            RemoteCommand.guide, .channelUp, .channelDown, .digit7, .inputSource,
        ])
    func screenChangingCommandInvalidatesPreviousIME(command: RemoteCommand) async throws {
        try await assertScreenChangeInvalidatesIME(command: command)
    }

    private func assertScreenChangeInvalidatesIME(command: RemoteCommand?) async throws {
        let channel = PairingFixtureChannel()
        let coordinator = SonyPairingCoordinator(controlChannel: channel, keyboardPreference: { _ in true })
        let television = ConnectedTV(
            brand: .sony, reportedDeviceID: "synthetic-ime-tv",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.88"),
            modelName: "Synthetic Model", firmwareVersion: nil, powerState: .on)
        try await coordinator.installSyntheticSessionForTesting(television, reportedFeatures: 615)
        await channel.openSyntheticControl()
        await coordinator.focusSyntheticFieldForTesting()
        if let command {
            try await coordinator.send(command)
        } else {
            _ = try await coordinator.convenience(.launch(TVAppShortcut.sonyConfiguredLinks[0]))
        }
        let text = try RemoteTextInput("synthetic Unicode 😀")
        await #expect(throws: TVConvenienceError.textFieldNotFocused) {
            try await coordinator.sendText(text)
        }
        #expect(await channel.textCount == 0)
        await coordinator.focusSyntheticFieldForTesting(imeCounter: nil)
        await #expect(throws: TVConvenienceError.textFieldNotFocused) {
            try await coordinator.sendText(text)
        }
        await coordinator.focusSyntheticFieldForTesting(imeCounter: 2)
        try await coordinator.sendText(text)
        #expect(await channel.textCount == 1)
        await coordinator.disconnect()
    }
}

/// All certificates are generated in memory; no keychain, credential, household TV, or network is used.
private struct SyntheticPairingMaterial: Sendable {
    let identity: SonyClientIdentityReference
    let peerA: SonyTLSPeer
    let peerB: SonyTLSPeer
    let credentialB: SonyPairingCredential
    let targetA: TVConnectionTarget
    let targetB: TVConnectionTarget
    let codeA: String
    let codeB: String

    init() throws {
        let client = try Self.certificate("Synthetic Client", serial: 1)
        let a = try Self.certificate("Synthetic TV A", serial: 2)
        let b = try Self.certificate("Synthetic TV B", serial: 3)
        identity = SonyClientIdentityReference(syntheticCertificate: client)
        peerA = Self.peer(a, name: "Synthetic TV A")
        peerB = Self.peer(b, name: "Synthetic TV B")
        credentialB = try SonyPairingCredential(certificateSHA256: peerB.certificateSHA256)
        targetA = TVConnectionTarget(
            brand: .sony, reportedDeviceID: "synthetic-advertisement-a",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.101"), controlPort: 6466)
        targetB = TVConnectionTarget(
            brand: .sony, reportedDeviceID: "synthetic-advertisement-b",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.102"), controlPort: 6466)
        codeA = try SonyPairingSecret.displayCode(
            suffix: Data([1, 2]), clientCertificate: client, serverCertificate: a)
        codeB = try SonyPairingSecret.displayCode(
            suffix: Data([3, 4]), clientCertificate: client, serverCertificate: b)
    }

    private static func certificate(_ name: String, serial: UInt8) throws -> SecCertificate {
        var error: Unmanaged<CFError>?
        let key = try #require(
            SecKeyCreateRandomKey(
                [
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                    kSecAttrKeySizeInBits as String: 2_048,
                    kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
                ]
                    as CFDictionary, &error))
        return try SonyClientCertificateFactory.make(
            privateKey: key, commonName: name, serialNumber: Data(repeating: serial, count: 16))
    }

    private static func peer(_ certificate: SecCertificate, name: String) -> SonyTLSPeer {
        let data = SecCertificateCopyData(certificate) as Data
        return SonyTLSPeer(
            certificateDER: data, certificateSHA256: Data(SHA256.hash(data: data)), displayName: name)
    }
}

private actor HeldSonyCredentialStore: SonyPairingCredentialStoring {
    private let peerA: SonyTLSPeer
    private let holdSave: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var held = false
    private var started: CheckedContinuation<Void, Never>?
    private(set) var heldLookupCount = 0
    private(set) var heldSaveCount = 0
    init(peerA: SonyTLSPeer, holdSave: Bool) {
        self.peerA = peerA
        self.holdSave = holdSave
    }
    func credential(for fingerprint: Data) async throws -> SonyPairingCredential? {
        guard fingerprint == peerA.certificateSHA256, !holdSave else { return nil }
        heldLookupCount += 1
        await hold()
        return try SonyPairingCredential(certificateSHA256: fingerprint)
    }
    func save(_ credential: SonyPairingCredential) async {
        guard holdSave, credential.certificateSHA256 == peerA.certificateSHA256 else { return }
        heldSaveCount += 1
        await hold()
    }
    func remove(reportedDeviceID: String) {}
    private func hold() async {
        held = true
        await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilHeld() async {
        guard !held else { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseHeld() {
        continuation?.resume()
        continuation = nil
    }
}

private actor HeldSonyPairingCode {
    private var requested = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        requested = true
        await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilRequested() async {
        guard !requested else { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PairingFixtureChannel: SonyTLSChanneling {
    private let material: SyntheticPairingMaterial?
    private let isControl: Bool
    private var messages: [Data] = []
    private var receiveWaiters: [UUID: CheckedContinuation<Data, Error>] = [:]
    private(set) var activeLabel: String?
    private(set) var disconnectCount = 0
    private(set) var commandCount = 0
    private(set) var textCount = 0
    private var shouldHoldLaunch = false
    private var launchContinuation: CheckedContinuation<Void, Never>?
    private var launchStarted: CheckedContinuation<Void, Never>?
    init(material: SyntheticPairingMaterial? = nil, isControl: Bool = true) {
        self.material = material
        self.isControl = isControl
    }
    func connect(
        address: PrivateIPv4Address, port: UInt16, identity: SonyClientIdentityReference,
        trustMode: SonyTLSTrustMode
    ) throws -> SonyTLSPeer {
        let material = try #require(material)
        let isA = address == material.targetA.address
        activeLabel = isA ? "A" : "B"
        if isControl {
            let info = SonyProtobuf.stringField(1, "Synthetic Model") + SonyProtobuf.stringField(2, "Sony")
            messages = [
                SonyProtobuf.bytesField(
                    1, SonyProtobuf.varintField(1, 615) + SonyProtobuf.bytesField(2, info)),
                SonyProtobuf.bytesField(40, SonyProtobuf.varintField(1, 1)),
            ]
        } else {
            messages = [11, 20, 31, 41].map {
                SonyProtobuf.varintField(2, 200) + SonyProtobuf.bytesField($0, Data())
            }
        }
        return isA ? material.peerA : material.peerB
    }
    func send(_ message: Data) async throws {
        guard activeLabel != nil else { throw SonyTLSChannelError.connectionClosed }
        let fields = try SonyProtobuf.fields(in: message)
        if fields.contains(where: { $0.number == 21 }) { textCount += 1 }
        if fields.contains(where: { $0.number == 10 }) { commandCount += 1 }
        if shouldHoldLaunch, fields.contains(where: { $0.number == 90 }) {
            shouldHoldLaunch = false
            await withCheckedContinuation {
                launchContinuation = $0
                launchStarted?.resume()
                launchStarted = nil
            }
        }
    }
    func receive() async throws -> Data {
        guard activeLabel != nil else { throw SonyTLSChannelError.connectionClosed }
        if !messages.isEmpty { return messages.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receiveWaiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelReceive(id) }
        }
    }
    private func cancelReceive(_ id: UUID) {
        receiveWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func checkConnection() throws {
        guard activeLabel != nil else { throw SonyTLSChannelError.connectionClosed }
    }
    func disconnect() {
        disconnectCount += 1
        activeLabel = nil
        messages = []
        let pending = receiveWaiters.values
        receiveWaiters = [:]
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }
    func openSyntheticControl() { activeLabel = "Synthetic" }
    func holdNextLaunch() { shouldHoldLaunch = true }
    func waitUntilLaunchStarted() async {
        guard launchContinuation == nil else { return }
        await withCheckedContinuation { launchStarted = $0 }
    }
    func releaseLaunch() {
        launchContinuation?.resume()
        launchContinuation = nil
    }
}
