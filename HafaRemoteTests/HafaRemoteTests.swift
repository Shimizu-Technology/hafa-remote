import Foundation
import Testing

@testable import HafaRemote

/// Foundation tests that hold release metadata to the product's privacy promise.
struct HafaRemoteTests {
    @Test("Recovery actions stay available after automatic attempts and preserve trust recovery")
    func recoveryActionsMatchSessionProblem() {
        #expect(RemoteSessionState.offline.recoveryActions.contains(.retryConnection))
        #expect(RemoteSessionState.reconnecting(attempt: 5).recoveryActions.contains(.findTV))
        #expect(!RemoteSessionState.certificateChanged.recoveryActions.contains(.retryConnection))
        #expect(RemoteSessionState.certificateChanged.recoveryActions.contains(.findTV))
        #expect(RemoteSessionState.pairing.recoveryActions.isEmpty)
    }

    @Test("Implemented, reported and hardware verified capabilities remain distinct")
    func capabilityEvidenceDoesNotInventVerification() {
        let evidence = TVCapabilityEvidence(
            implemented: [.navigation, .volume, .powerOn],
            protocolReported: [.navigation, .volume, .textInput],
            hardwareVerified: [.navigation, .textInput]
        )
        #expect(evidence.internalAvailable == [.navigation, .volume])
        #expect(evidence.publiclyAvailable == [.navigation])
        #expect(!evidence.hardwareVerified.contains(.textInput))
        #expect(TVCapabilityEvidence(implemented: [.powerOn]).hardwareVerified.isEmpty)
    }

    @Test(
        "Every unresolved brand is denied public distribution and available for internal testing",
        arguments: TVBrand.allCases)
    func distributionRequiresExplicitInternalAudience(brand: TVBrand) {
        #expect(TVDistributionPolicy.internalCandidate.permits(brand))
        #expect(!TVDistributionPolicy.publicRelease.permits(brand))
    }

    @Test("A connected socket defaults to unknown screen power without hardware verification")
    func connectionDoesNotProveAwakeOrWake() throws {
        let tv = ConnectedTV(
            brand: .sony, reportedDeviceID: "synthetic-tv",
            address: try PrivateIPv4Address(documentationAddressForTesting: "192.0.2.43"),
            modelName: "Synthetic Sony", firmwareVersion: nil
        )
        #expect(tv.powerState == .unknown)
        #expect(tv.capabilityEvidence.protocolReported == nil)
        #expect(tv.capabilityEvidence.hardwareVerified.isEmpty)
        let standby = tv.applying(
            TVSessionObservation(stableDeviceKey: tv.stableDeviceKey, powerState: .standby))
        #expect(standby.powerState == .standby)
        #expect(standby.forgettingPowerObservation.powerState == .unknown)
        #expect(
            tv.applying(TVSessionObservation(stableDeviceKey: "sony:synthetic-other-tv", powerState: .on))
                == tv)
    }

    @Test("Implemented capabilities stay brand-neutral and truthful")
    func implementedCapabilities() {
        let samsung = TVCapability.implemented(for: .samsung)
        let sony = TVCapability.implemented(for: .sony)
        let vizio = TVCapability.implemented(for: .vizio)

        #expect(samsung.contains(.textInput))
        #expect(!sony.contains(.textInput))
        #expect(!vizio.contains(.textInput))
        #expect(!samsung.contains(.powerOn))
        #expect(sony.contains(.powerOn))
        #expect(vizio.contains(.powerOn))
    }

    @Test("An explicit device capability set remains authoritative")
    func explicitCapabilitiesRemainAuthoritative() throws {
        let tv = ConnectedTV(
            brand: .samsung,
            reportedDeviceID: "synthetic-device-id",
            address: try PrivateIPv4Address("192.168.10.20"),
            modelName: "Q70AA",
            firmwareVersion: nil,
            networkConnection: .wireless,
            macAddress: try TVMACAddress("02:00:5E:10:00:01"),
            capabilities: [.navigation]
        )

        #expect(tv.capabilities == [.navigation])
    }

    /// Verifies the user-facing name and required platform declarations in the built app.
    @Test("The shipped metadata matches the product's privacy promise")
    func appMetadataMatchesPrivacyPromise() throws {
        let bundle = Bundle.main

        #expect(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Hafa Remote")
        #expect(bundle.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)

        let localNetworkCopy = try #require(
            bundle.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        )
        #expect(localNetworkCopy.contains("supported TVs"))

        let bonjourServices = try #require(
            bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        )
        #expect(
            bonjourServices
                == ["_androidtvremote2._tcp", "_samsungmsf._tcp", "_viziocast._tcp"]
        )
    }

    @MainActor
    @Test("Dismissing text input cancels its pending delivery")
    func textInputDismissalCancelsPendingDelivery() async throws {
        let controller = SamsungTextDeliveryController()
        let probe = SuspendedTextDeliveryProbe()
        let input = try RemoteTextInput("Håfa")

        controller.send(input) { input in
            try await probe.suspend(input)
        }

        #expect(await probe.nextStartedCharacterCount() == 4)
        #expect(controller.isSending)

        controller.cancel()

        #expect(await probe.nextCancellation() == true)
        #expect(!controller.isSending)
        #expect(controller.result == nil)
    }
}

private actor SuspendedTextDeliveryProbe {
    private let started: AsyncStream<Int>
    private let startedContinuation: AsyncStream<Int>.Continuation
    private let cancellations: AsyncStream<Bool>
    private let cancellationContinuation: AsyncStream<Bool>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream.makeStream()
        (cancellations, cancellationContinuation) = AsyncStream.makeStream()
    }

    func suspend(_ input: RemoteTextInput) async throws {
        startedContinuation.yield(input.value.count)
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancellationContinuation.yield(true)
            throw CancellationError()
        }
    }

    func nextStartedCharacterCount() async -> Int? {
        var iterator = started.makeAsyncIterator()
        return await iterator.next()
    }

    func nextCancellation() async -> Bool? {
        var iterator = cancellations.makeAsyncIterator()
        return await iterator.next()
    }
}
