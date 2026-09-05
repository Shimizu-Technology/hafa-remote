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
        #expect(localNetworkCopy.contains("supported TVs"))

        let bonjourServices = try #require(
            bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        )
        #expect(bonjourServices == ["_androidtvremote2._tcp", "_samsungmsf._tcp"])
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
