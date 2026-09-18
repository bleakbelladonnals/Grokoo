import Foundation

/// State time is independent of Gateway revisions and of desktop travel.
/// Pausing drops the wall-clock anchor, so hidden/sleep time is never caught up.
struct PresenceMotionClock {
    private(set) var state: PresenceState
    private(set) var elapsed: TimeInterval = 0
    private var previousTime: TimeInterval?
    let phaseSlot: Int
    var phaseDelay: TimeInterval { Double(phaseSlot) * (state == .done ? 6.2 / 6 : 0.18) }

    init(state: PresenceState = .idle, phaseSlot: Int = 0) {
        self.state = state
        self.phaseSlot = phaseSlot
    }

    @discardableResult
    mutating func setState(_ state: PresenceState) -> Bool {
        guard self.state != state else { return false }
        self.state = state
        elapsed = 0
        previousTime = nil
        return true
    }

    mutating func advance(to now: TimeInterval, running: Bool) {
        guard running else { pause(); return }
        if let previousTime {
            let delta = now - previousTime
            // Menu tracking, sleep or a suspended runloop must not replay missed frames.
            if delta >= 0, delta < 0.5 { elapsed += delta }
        }
        previousTime = now
    }

    mutating func pause() { previousTime = nil }

    var sampleTime: TimeInterval {
        // Delay, rather than skip, the first celebration/spin for each member.
        // The same offset remains across repeats and never changes on reordering.
        switch state {
        case .working, .done: max(0, elapsed - phaseDelay)
        default: elapsed
        }
    }
}
