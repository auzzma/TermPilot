import AppKit

/// Converts AppKit's pixel/line deltas to Apple screen sharing's wheel pulses.
/// The Apple server reports each pulse as one precise pixel, not a wheel line.
/// Keep sub-pixel movement across events, including the
/// momentum tail, so the result depends on distance rather than event count.
struct ScreenSharingScrollState {
    private var remainder = 0.0
    private var lastTimestamp: TimeInterval?
    private var lastPrecise: Bool?

    mutating func reset() {
        remainder = 0
        lastTimestamp = nil
        lastPrecise = nil
    }

    mutating func commands(for event: NSEvent) -> [Int] {
        consume(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                timestamp: event.timestamp, startsGesture: event.phase.contains(.began) || event.phase.contains(.cancelled))
    }

    mutating func consume(deltaY: Double, precise: Bool, timestamp: TimeInterval,
                          startsGesture: Bool = false) -> [Int] {
        guard deltaY.isFinite, timestamp.isFinite else { reset(); return [] }
        if startsGesture || lastPrecise != precise ||
            lastTimestamp.map({ timestamp < $0 || timestamp - $0 > 0.3 }) == true {
            reset()
        }
        lastTimestamp = timestamp
        lastPrecise = precise
        // AppKit's point and line wheel units have a 10:1 scale. Do not apply
        // natural-scroll inversion again: scrollingDeltaY already includes it.
        let steps = -deltaY * (precise ? 1 : 10)
        if steps == 0 { return [] }
        if remainder * steps < 0 { remainder = 0 }
        // Bound malformed input without leaving a delayed scroll backlog.
        let total = remainder + min(1000, max(-1000, steps))
        var whole = Int(total.rounded(.towardZero))
        remainder = total - Double(whole)
        var commands: [Int] = []
        // The screen engine accepts at most ten steps per command. Split a
        // fast swipe instead of letting its remaining distance get clamped.
        while whole != 0 {
            let chunk = min(10, max(-10, whole))
            commands.append(chunk)
            whole -= chunk
        }
        return commands
    }
}
