import Foundation

public struct ScreenSharingPerformance: Sendable {
    public let framesPerSecond: Double?
    public let receiveBytesPerSecond: Double?
    public let sendBytesPerSecond: Double?
    public static let unavailable = Self(framesPerSecond: nil, receiveBytesPerSecond: nil, sendBytesPerSecond: nil)
}

/// FPS counts fresh compositions submitted to Metal, not repeated display-link
/// callbacks or the number of independently decoded video tiles.
struct ScreenSharingPerformanceMeter {
    private var frames = 0
    private var sampleTime: TimeInterval
    private var trafficTime: TimeInterval?
    private var received: Double?
    private var sent: Double?

    init(now: TimeInterval) { sampleTime = now }
    mutating func presentedFrame() { frames += 1 }
    mutating func receiveTraffic(received: Double?, sent: Double?, now: TimeInterval) {
        guard let received, let sent, received.isFinite, sent.isFinite,
              received >= 0, sent >= 0 else { return }
        self.received = received; self.sent = sent; trafficTime = now
    }
    mutating func sample(now: TimeInterval) -> ScreenSharingPerformance {
        let elapsed = now - sampleTime
        guard elapsed > 0 else { return .unavailable }
        let fresh = trafficTime.map { now - $0 >= 0 && now - $0 < 3 } ?? false
        let result = ScreenSharingPerformance(framesPerSecond: Double(frames) / elapsed,
            receiveBytesPerSecond: fresh ? received : nil, sendBytesPerSecond: fresh ? sent : nil)
        frames = 0; sampleTime = now
        return result
    }
}
