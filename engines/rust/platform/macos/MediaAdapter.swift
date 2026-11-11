// TermPilot platform adapter. Protocols, transport, ordering and recovery live
// in Rust; this file only calls the public system media frameworks.
import Foundation
import VideoToolbox
import AudioToolbox

public typealias MediaOutput = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafePointer<UInt64>, UnsafePointer<UInt8>, Int) -> Void
private final class MediaDecoder {
    let output: MediaOutput
    let context: UnsafeMutableRawPointer?
    var video: VTDecompressionSession?
    var format: CMFormatDescription?
    var audio: AudioConverterRef?
    var audioConfiguration: [UInt8] = [0xf8,0xe6,0x51,0x32,0xe0,0]
    var audioInput: NSData?
    var audioConsumed = false
    let packet = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    let lock = NSLock()
    var produced: UInt64 = 0
    var sequence: Int64 = 0
    var failed = false
    var avc = false
    init(_ output: @escaping MediaOutput, _ context: UnsafeMutableRawPointer?) {
        self.output = output; self.context = context
        packet.initialize(to: AudioStreamPacketDescription())
    }
    deinit {
        if let video { VTDecompressionSessionWaitForAsynchronousFrames(video); VTDecompressionSessionInvalidate(video) }
        if let audio { AudioConverterDispose(audio) }
        packet.deinitialize(count: 1); packet.deallocate()
    }
    func publish(_ image: CVImageBuffer, token: UInt) {
        guard [OSType(0x34343466), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(CVPixelBufferGetPixelFormatType(image)),
              CVPixelBufferGetPlaneCount(image) == 2 else { lock.lock(); failed = true; lock.unlock(); return }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else { return }
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == 0 else { return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let ys = CVPixelBufferGetBytesPerRowOfPlane(image, 0), us = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let yh = CVPixelBufferGetHeightOfPlane(image, 0), uh = CVPixelBufferGetHeightOfPlane(image, 1)
        let uw = CVPixelBufferGetWidthOfPlane(image, 1)
        guard ys >= width, us >= uw * 2, ys <= 65536, us <= 131072, yh == height, (uh == height || uh == (height + 1) / 2),
              ys * yh + us * uh <= 64 * 1024 * 1024,
              let y = CVPixelBufferGetBaseAddressOfPlane(image, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return }
        var pixels = Data(bytes: y, count: ys * yh); pixels.append(uv.assumingMemoryBound(to: UInt8.self), count: us * uh)
        let metadata: [UInt64] = [UInt64((token >> 16) & 15), UInt64(token & 65535), UInt64(width), UInt64(height), UInt64(ys), UInt64(us), UInt64(uw), UInt64(uh), UInt64(ys * yh), UInt64(us * uh)]
        metadata.withUnsafeBufferPointer { meta in pixels.withUnsafeBytes { bytes in output(context, 1, meta.baseAddress!, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count) } }
        lock.lock(); produced += 1; lock.unlock()
    }
}
@_cdecl("tp_media_create")
public func mediaCreate(_ output: @escaping MediaOutput, _ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(MediaDecoder(output, context)).toOpaque()
}
@_cdecl("tp_media_destroy")
public func mediaDestroy(_ handle: UnsafeMutableRawPointer) { Unmanaged<MediaDecoder>.fromOpaque(handle).release() }

@_cdecl("tp_video_configure")
public func videoConfigure(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    // Rust worker threads have no AppKit run-loop autorelease pool.
    return autoreleasepool { videoConfigureInPool(handle, bytes, size) }
}
private func videoConfigureInPool(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    guard size >= 4, size <= 65536 else { return -1 }
    let decoder = Unmanaged<MediaDecoder>.fromOpaque(handle).takeUnretainedValue()
    var offset = 0, params: [NSData] = []
    while offset < size {
        guard offset + 4 <= size, params.count < 18 else { return -1 }
        let n = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3]); offset += 4
        guard n >= 2, n <= size - offset else { return -1 }
        params.append(NSData(bytes: bytes.advanced(by: offset), length: n)); offset += n
    }
    guard let first = params.first else { return -1 }
    let avc = first.bytes.assumingMemoryBound(to: UInt8.self).pointee & 31 == 7
    guard params.count >= (avc ? 2 : 3) else { return -1 }
    let pointers = params.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }, sizes = params.map { $0.length }
    var format: CMFormatDescription?
    let status = avc ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: params.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format) : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: params.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
    guard status == 0, let format else { return status == 0 ? -1 : status }
    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { opaque, token, status, flags, image, _, _ in
        guard let opaque else { return }
        let decoder = Unmanaged<MediaDecoder>.fromOpaque(opaque).takeUnretainedValue()
        guard status == 0, !flags.contains(.frameDropped), let image else { decoder.lock.lock(); decoder.failed = true; decoder.lock.unlock(); return }
        autoreleasepool { decoder.publish(image, token: UInt(bitPattern: token)) }
    }, decompressionOutputRefCon: handle)
    var session: VTDecompressionSession?
    let attributes = [kCVPixelBufferPixelFormatTypeKey: avc ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : OSType(0x34343466)] as CFDictionary
    let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: &callback, decompressionSessionOut: &session)
    guard result == 0, let session else { return result == 0 ? -1 : result }
    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    if let old = decoder.video { VTDecompressionSessionWaitForAsynchronousFrames(old); VTDecompressionSessionInvalidate(old) }
    decoder.video = session; decoder.format = format; decoder.avc = avc; return 0
}
@_cdecl("tp_video_decode")
public func videoDecode(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ size: Int, _ tile: UInt32, _ donl: UInt32) -> Int32 {
    // Rust worker threads have no AppKit run-loop autorelease pool.
    return autoreleasepool { videoDecodeInPool(handle, bytes, size, tile, donl) }
}
private func videoDecodeInPool(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ size: Int, _ tile: UInt32, _ donl: UInt32) -> Int32 {
    guard size >= 2, size <= 16 * 1024 * 1024, tile < 16, donl <= 65535 else { return -1 }
    let decoder = Unmanaged<MediaDecoder>.fromOpaque(handle).takeUnretainedValue()
    guard let session = decoder.video, let format = decoder.format else { return -2 }
    // AVC input is a complete AVCC access unit; HEVC input is a single NAL.
    let prefix = decoder.avc ? 0 : 4
    if decoder.avc {
        var at = 0
        while at < size {
            guard at + 4 <= size else { return -1 }
            let n = Int(bytes[at]) << 24 | Int(bytes[at+1]) << 16 | Int(bytes[at+2]) << 8 | Int(bytes[at+3]); at += 4
            guard n > 0, n <= size - at else { return -1 }; at += n
        }
    }
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size + prefix, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: size + prefix, flags: 0, blockBufferOut: &block)
    guard status == 0, let block else { return status == 0 ? -3 : status }
    var length = UInt32(size).bigEndian
    if prefix > 0 { status = withUnsafePointer(to: &length) { CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4) } }
    guard status == 0 else { return status }
    status = CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: prefix, dataLength: size)
    guard status == 0 else { return status }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: decoder.sequence, timescale: 60), decodeTimeStamp: .invalid)
    var sampleSize = size + prefix, sample: CMSampleBuffer?
    status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
    guard status == 0, let sample else { return status == 0 ? -4 : status }
    decoder.lock.lock(); decoder.failed = false; let before = decoder.produced; decoder.lock.unlock()
    // Token is never dereferenced. Zero is valid (tile 0, DONL 0).
    let token = UnsafeMutableRawPointer(bitPattern: Int(tile << 16 | donl))
    decoder.sequence += 1
    status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: token, infoFlagsOut: nil)
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    decoder.lock.lock(); defer { decoder.lock.unlock() }
    if status != 0 { return status }
    if decoder.failed { return -5 }
    return decoder.produced > before ? 1 : 0
}
@_cdecl("tp_audio_decode")
public func audioDecode(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    // Rust worker threads have no AppKit run-loop autorelease pool.
    return autoreleasepool { audioDecodeInPool(handle, bytes, size) }
}
private func audioDecodeInPool(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    guard size > 0, size <= 65536 else { return -1 }
    let decoder = Unmanaged<MediaDecoder>.fromOpaque(handle).takeUnretainedValue()
    if decoder.audio == nil {
        var input = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC_ELD_SBR, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == 0, let converter else { return status == 0 ? -2 : status }
        let n = UInt8(decoder.audioConfiguration.count)
        let cookie: [UInt8] = [0x03,0x80,0x80,0x80,n+32,0,0,0,0x04,0x80,0x80,0x80,n+18,0x40,0x14,0,0,0,0,0,0,0,0,0,0,0,0x05,0x80,0x80,0x80,n] + decoder.audioConfiguration + [0x06,0x80,0x80,0x80,0x01,0x02]
        let cookieStatus = cookie.withUnsafeBytes { AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!) }
        guard cookieStatus == 0 else { AudioConverterDispose(converter); return cookieStatus }
        decoder.audio = converter
    }
    guard let converter = decoder.audio else { return -2 }
    decoder.audioInput = NSData(bytes: bytes, length: size); decoder.audioConsumed = false
    defer { decoder.audioInput = nil }
    var buffer = [Float](repeating: 0, count: 960), frames: UInt32 = 480
    let status = buffer.withUnsafeMutableBytes { output in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(output.count), mData: output.baseAddress))
        return AudioConverterFillComplexBuffer(converter, { _, count, list, descriptions, opaque in
            guard let opaque else { return -1 }
            let decoder = Unmanaged<MediaDecoder>.fromOpaque(opaque).takeUnretainedValue()
            guard !decoder.audioConsumed, let input = decoder.audioInput else { count.pointee = 0; return 1 }
            decoder.audioConsumed = true; count.pointee = 1
            list.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(input.length), mData: UnsafeMutableRawPointer(mutating: input.bytes))
            decoder.packet.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(input.length))
            descriptions?.pointee = decoder.packet; return 0
        }, handle, &frames, &list, nil)
    }
    guard status == 0 || status == 1 else { return status }
    guard frames > 0, frames <= 480 else { return 0 }
    let metadata = [UInt64](repeating: 0, count: 10)
    metadata.withUnsafeBufferPointer { meta in buffer.withUnsafeBytes { bytes in decoder.output(decoder.context, 2, meta.baseAddress!, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), Int(frames) * 8) } }
    return Int32(frames)
}

// Explicit codec configuration is used by platform conformance probes; existing
// connections retain their unchanged Apple screen-sharing default configuration.
@_cdecl("tp_audio_configure")
public func audioConfigure(_ handle: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    guard size > 0, size <= 64 else { return -1 }
    let decoder = Unmanaged<MediaDecoder>.fromOpaque(handle).takeUnretainedValue()
    if let audio = decoder.audio { AudioConverterDispose(audio); decoder.audio = nil }
    decoder.audioConfiguration = Array(UnsafeBufferPointer(start: bytes, count: size))
    return 0
}
