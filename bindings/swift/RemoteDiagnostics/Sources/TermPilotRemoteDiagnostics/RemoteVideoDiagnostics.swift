import Foundation

/// Only media statistics are decoded. Connection configuration, clipboard and file paths
/// are deliberately excluded from the copyable report.
public struct RemoteMediaDiagnostics: Codable, Sendable {
    public var videoCodec: String?
    public var nativeDecoder: String?
    public var nativeColorFormat: Int64?
    public var nativeSubmitted: Int64?
    public var nativeOutputs: Int64?
    public var videoPackets: Int64?
    public var frames: Int64?
    public var decodeErrors: Int64?
    public var dropped: Int64?
    public var receiveQueueDrops: Int64?
    public var decodeQueueDrops: Int64?
    public var oversizedPackets: Int64?
    public var assemblyDrops: Int64?
    public var lateUnits: Int64?
    public var missingUnits: Int64?
    public var codecQueueDrops: Int64?
    public var recoverySkips: Int64?
    public var overloadRecoveries: Int64?
    public var decoderResets: Int64?
    public var sessionRecoveries: Int64?
    public var decodeMicros: Double?
    public var decodeCalls: Int64?
    public var maxDecodeMicros: Double?
    public var maxQueueMicros: Double?
    public var audioDecodeErrors: Int64?
    public var lastVideoDecodeError: Int64?

    public func report() -> String {
        func n(_ value: Int64?) -> String { value.map(String.init) ?? "—" }
        func ms(_ value: Double?) -> String {
            value.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0 / 1000) } ?? "—"
        }
        let average = decodeCalls.flatMap { calls in calls > 0 ? decodeMicros.map { $0 / Double(calls) } : nil }
        let videoErrors = decodeErrors.flatMap { total in audioDecodeErrors.map { max(0, total - $0) } }
        var lines = ["Video codec: \(videoCodec ?? "—")"]
        if let decoder = nativeDecoder, !decoder.isEmpty {
            lines += ["Decoder: \(decoder) · Color: \(n(nativeColorFormat))",
                      "Current decoder input/output: \(n(nativeSubmitted)) / \(n(nativeOutputs))"]
        }
        lines += [
            "Video packets: \(n(videoPackets))",
            "Decoded: \(n(frames)) · Decode errors: \(n(decodeErrors)) · Dropped: \(n(dropped))",
            "Receive queue drops: \(n(receiveQueueDrops)) packets · Assembly queue drops: \(n(decodeQueueDrops)) packets",
            "Oversized packets: \(n(oversizedPackets))",
            "Assembly expired: \(n(assemblyDrops)) units · Late units: \(n(lateUnits)) · Missing sequence: \(n(missingUnits))",
            "Codec queue drops: \(n(codecQueueDrops)) units · Recovery skips: \(n(recoverySkips))",
            "Overload recoveries: \(n(overloadRecoveries)) · Decoder resets: \(n(decoderResets))",
            "Session media restarts: \(n(sessionRecoveries))",
            "Decode time: \(ms(average)) ms avg · \(ms(maxDecodeMicros)) ms max · Queue wait: \(ms(maxQueueMicros)) ms max",
            "Video errors: \(n(videoErrors)) · Last code: \(n(lastVideoDecodeError)) · Audio errors: \(n(audioDecodeErrors))"
        ]
        return lines.joined(separator: "\n")
    }
}

/// Counts are session-local. Receiving counts decoded pictures/tiles delivered to the
/// client; rendering counts fresh compositions submitted to the GPU, not display ticks.
public struct RemoteVideoDiagnostics: Sendable {
    public var receivedFrames: Int64 = 0
    public var renderedFrames: Int64 = 0
    public var lastFrameAt: TimeInterval?
    public var lastRenderedAt: TimeInterval?
    public var renderer = ""
    public var videoError = ""
    public var media: RemoteMediaDiagnostics?
    public init() {}
    public mutating func received(now: TimeInterval) { receivedFrames += 1; lastFrameAt = now }
    public mutating func rendered(now: TimeInterval) { renderedFrames += 1; lastRenderedAt = now }
    public func report(platform: String, mode: String, resolution: String, fps: Double?,
                       received: Double?, sent: Double?, now: TimeInterval,
                       localize: (String) -> String = { $0 }) -> String {
        func age(_ time: TimeInterval?) -> String {
            time.map { String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), max(0, now - $0)) } ?? localize("暂无")
        }
        func rate(_ number: Double?, scale: Double = 1) -> String {
            guard let number, number.isFinite else { return "—" }
            return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(0, number) / scale)
        }
        var lines = [platform, "\(mode) · \(resolution)",
            "\(rate(fps)) FPS · ↓ \(rate(received, scale: 1024)) KiB/s · ↑ \(rate(sent, scale: 1024)) KiB/s",
            "\(localize("接收画面")): \(receivedFrames) · \(age(lastFrameAt))",
            "\(localize("绘制画面")): \(renderedFrames) · \(age(lastRenderedAt))",
            "\(localize("画面错误")): \(videoError.isEmpty ? localize("无") : videoError)"]
        if !renderer.isEmpty { lines.append(renderer) }
        if let media { lines.append(media.report()) }
        return lines.joined(separator: "\n")
    }
}
