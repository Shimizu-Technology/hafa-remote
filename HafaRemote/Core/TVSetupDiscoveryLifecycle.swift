/// Controls setup discovery without taking ownership of the TV connection or pairing.
struct TVSetupDiscoveryLifecycle {
    enum Action: Equatable { case none, start, stop }

    private var isVisible = false
    private var wasForeground = true
    private var needsSearch = true
    private var ownsSearch = false

    mutating func appear(wifi: Bool?, foreground: Bool, blocked: Bool) -> Action {
        isVisible = true
        needsSearch = true
        return update(wifi: wifi, foreground: foreground, blocked: blocked)
    }

    mutating func update(wifi: Bool?, foreground: Bool, blocked: Bool) -> Action {
        if !foreground || wifi == false { needsSearch = true }
        if foreground && !wasForeground { needsSearch = true }
        wasForeground = foreground
        guard isVisible else { return .none }
        guard foreground, wifi != false, !blocked else {
            guard ownsSearch else { return .none }
            ownsSearch = false
            return .stop
        }
        guard needsSearch else { return .none }
        needsSearch = false
        ownsSearch = true
        return .start
    }

    mutating func requestSearch(wifi: Bool?, foreground: Bool, blocked: Bool) -> Action {
        needsSearch = true
        return update(wifi: wifi, foreground: foreground, blocked: blocked)
    }

    mutating func selectTV() {
        needsSearch = false
        ownsSearch = false
    }

    mutating func disappear() {
        isVisible = false
        ownsSearch = false
        needsSearch = false
    }
}
