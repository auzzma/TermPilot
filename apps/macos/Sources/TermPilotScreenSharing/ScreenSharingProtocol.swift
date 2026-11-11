import Foundation
import TermPilotRemoteDiagnostics

struct ScreenSharingMessage: Codable, Sendable {
    var kind: String
    var mediaDiagnostics: RemoteMediaDiagnostics?
    var payloadLength: Int
    var id: String?
    var endpoint: String?
    var sha256: String?
    var accepted: Bool?
    var offerId: String?
    var message: String?
    var code: String?
    var error: String?
    var stage: String?
    var text: String?
    var decoder: String?
    var brokerPID: Int32?
    var requestID: String?
    var hasText: Bool?
    var paths: [String]?
    var dragID: UInt32?
    var name: String?
    var direction: String?
    var completedBytes: Int64?
    var totalBytes: Int64?
    var receiveBytesPerSecond: Double?
    var sendBytesPerSecond: Double?
    var tile: Int?
    var width: Int?
    var height: Int?
    var yStride: Int?
    var uvStride: Int?
    var chromaWidth: Int?
    var chromaHeight: Int?
    var biplanar: Bool?
    var pixelFormat: String?
    var yLength: Int?
    var uLength: Int?
    var vLength: Int?
}

enum ScreenSharingWireError: Error { case invalidMessage }

struct ScreenSharingPacketDecoder {
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [(ScreenSharingMessage, Data)] {
        buffer.append(bytes)
        var packets: [(ScreenSharingMessage, Data)] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (2...65_536).contains(length) else { throw ScreenSharingWireError.invalidMessage }
            guard buffer.count >= 4 + length else { break }
            let headerData = Data(buffer.dropFirst(4).prefix(length))
            var header = try JSONDecoder().decode(ScreenSharingMessage.self, from: headerData)
            if header.kind == "mediaDiagnostics" {
                header.mediaDiagnostics = try JSONDecoder().decode(RemoteMediaDiagnostics.self, from: headerData)
            }
            let maximum = header.kind == "frame" ? 67_108_864 : 16_777_216
            guard (0...maximum).contains(header.payloadLength) else { throw ScreenSharingWireError.invalidMessage }
            let end = 4 + length + header.payloadLength
            guard buffer.count >= end else { break }
            let payload = Data(buffer.dropFirst(4 + length).prefix(header.payloadLength))
            if header.kind == "frame" { try ScreenSharingFrame.validate(header, payload: payload) }
            packets.append((header, payload))
            buffer = Data(buffer.dropFirst(end))
        }
        guard buffer.count <= 67_174_404 else { throw ScreenSharingWireError.invalidMessage }
        return packets
    }

    var hasIncompletePacket: Bool { !buffer.isEmpty }
}

struct ScreenSharingFrame: Sendable {
    let header: ScreenSharingMessage
    let data: Data

    static func validate(_ h: ScreenSharingMessage, payload: Data) throws {
        if h.pixelFormat == "bgrx" {
            guard h.tile == 0, let width = h.width, let height = h.height,
                  (1...8192).contains(width), (1...8192).contains(height),
                  width * height <= 16_777_216, h.yStride == width * 4,
                  payload.count == width * height * 4 else { throw ScreenSharingWireError.invalidMessage }
            return
        }
        guard h.pixelFormat == nil else { throw ScreenSharingWireError.invalidMessage }
        guard let tile = h.tile, (0..<16).contains(tile),
              let w = h.width, (1...3840).contains(w),
              let height = h.height, (1...2176).contains(height),
              let cw = h.chromaWidth, (1...w).contains(cw),
              let ch = h.chromaHeight, (1...height).contains(ch),
              let ys = h.yStride, (w...8192).contains(ys),
              let us = h.uvStride, ((h.biplanar == true ? cw * 2 : cw)...8192).contains(us),
              let yl = h.yLength, yl == ys * height,
              let ul = h.uLength, ul == us * ch,
              let vl = h.vLength, vl == (h.biplanar == true ? 0 : ul),
              payload.count == yl + ul + vl
        else { throw ScreenSharingWireError.invalidMessage }
    }
}

/// Bounded, latest-frame delivery prevents slow/hidden windows accumulating
/// video tasks on the main actor. Audio is limited to half a second.
final class ScreenSharingMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int: ScreenSharingFrame] = [:]
    private var audio: [Data] = []
    private var audioBytes = 0
    private var receivedFrames: Int64 = 0
    private var lastFrameAt: TimeInterval?
    func reception() -> (Int64, TimeInterval?) {
        lock.withLock { (receivedFrames, lastFrameAt) }
    }

    func put(_ frame: ScreenSharingFrame) {
        lock.withLock {
            frames[frame.header.tile!] = frame
            receivedFrames += 1; lastFrameAt = ProcessInfo.processInfo.systemUptime
        }
    }
    func takeFrames() -> [ScreenSharingFrame] {
        lock.withLock {
            defer { frames.removeAll(keepingCapacity: true) }
            return frames.values.sorted { $0.header.tile! < $1.header.tile! }
        }
    }
    func putAudio(_ data: Data) {
        guard data.count % 8 == 0, data.count <= 192_000 else { return }
        lock.withLock {
            audio.append(data); audioBytes += data.count
            while audioBytes > 192_000 { audioBytes -= audio.removeFirst().count }
        }
    }
    func takeAudio() -> [Data] {
        lock.withLock {
            defer { audio.removeAll(keepingCapacity: true); audioBytes = 0 }
            return audio
        }
    }
}
