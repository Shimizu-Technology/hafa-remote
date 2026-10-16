import Testing

@testable import HafaRemote

@MainActor
struct TVSetupDiscoveryLifecycleTests {
    @Test("An unknown initial Wi-Fi hint allows one scan, without restarting on the first available hint")
    func unknownHintDoesNotDuplicateScan() {
        var lifecycle = TVSetupDiscoveryLifecycle()
        #expect(lifecycle.appear(wifi: nil, foreground: true, blocked: false) == .start)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .none)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .none)
    }

    @Test("Initial unavailable Wi-Fi waits, then starts exactly one scan on return")
    func initiallyOfflineRecovers() {
        var lifecycle = TVSetupDiscoveryLifecycle()
        #expect(lifecycle.appear(wifi: false, foreground: true, blocked: false) == .none)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .start)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .none)
    }

    @Test("A lost path stops its old producer and a restored path starts a fresh scan")
    func pathFlapRestartsOnce() {
        var lifecycle = TVSetupDiscoveryLifecycle()
        #expect(lifecycle.appear(wifi: true, foreground: true, blocked: false) == .start)
        #expect(lifecycle.update(wifi: false, foreground: true, blocked: false) == .stop)
        #expect(lifecycle.update(wifi: false, foreground: true, blocked: false) == .none)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .start)
    }

    @Test("Wi-Fi return defers discovery during pairing and resumes after a failed attempt")
    func busyRecoveryIsDeferred() {
        var lifecycle = TVSetupDiscoveryLifecycle()
        _ = lifecycle.appear(wifi: true, foreground: true, blocked: false)
        lifecycle.selectTV()
        #expect(lifecycle.update(wifi: false, foreground: true, blocked: true) == .none)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: true) == .none)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .start)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .none)
    }

    @Test("Background work waits for foreground, including unchanged Wi-Fi after Settings")
    func foregroundReturnRechecksDiscovery() {
        var lifecycle = TVSetupDiscoveryLifecycle()
        _ = lifecycle.appear(wifi: true, foreground: true, blocked: false)
        #expect(lifecycle.update(wifi: true, foreground: false, blocked: false) == .stop)
        #expect(lifecycle.update(wifi: true, foreground: false, blocked: false) == .none)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .start)
    }

    @Test("Dismissal rejects deferred network and foreground recovery")
    func dismissedSetupCannotRestart() {
        var lifecycle = TVSetupDiscoveryLifecycle()
        _ = lifecycle.appear(wifi: false, foreground: true, blocked: false)
        lifecycle.disappear()
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .none)
        #expect(lifecycle.requestSearch(wifi: true, foreground: true, blocked: false) == .none)
    }

    @Test("Manual rescanning is bounded by visibility, foreground, path and connection ownership")
    func explicitRescanHonorsAvailability() {
        var lifecycle = TVSetupDiscoveryLifecycle()
        _ = lifecycle.appear(wifi: true, foreground: true, blocked: false)
        #expect(lifecycle.requestSearch(wifi: true, foreground: true, blocked: false) == .start)
        #expect(lifecycle.requestSearch(wifi: true, foreground: true, blocked: true) == .stop)
        #expect(lifecycle.update(wifi: true, foreground: true, blocked: false) == .start)
    }
}
