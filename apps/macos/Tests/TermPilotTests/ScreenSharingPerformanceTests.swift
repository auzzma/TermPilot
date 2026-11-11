import XCTest
@testable import TermPilotScreenSharing

final class ScreenSharingPerformanceTests: XCTestCase {
    func testEngineMediaDiagnosticsSurviveWireDecodingBeforeFirstFrame() throws {
        let header = Data(#"{"kind":"mediaDiagnostics","payloadLength":0,"videoCodec":"H.265","videoPackets":81689,"decodeErrors":40,"audioDecodeErrors":0,"lastVideoDecodeError":-1009}"#.utf8)
        let size = UInt32(header.count)
        let wire = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + header
        var parser = ScreenSharingPacketDecoder()
        let packets = try parser.append(wire)
        XCTAssertEqual(packets.count, 1)
        let report = try XCTUnwrap(packets.first?.0.mediaDiagnostics).report()
        XCTAssertTrue(report.contains("Video packets: 81689"))
        XCTAssertTrue(report.contains("Video errors: 40 · Last code: -1009"))
    }
    func testMailboxCountsEveryReceivedPictureEvenWhenAnOlderTileIsReplaced() throws {
        let header = try JSONDecoder().decode(ScreenSharingMessage.self, from: Data(#"{"kind":"frame","payloadLength":4,"tile":0,"width":1,"height":1,"pixelFormat":"bgrx","yStride":4}"#.utf8))
        let box = ScreenSharingMailbox()
        box.put(ScreenSharingFrame(header: header, data: Data(repeating: 0, count: 4)))
        box.put(ScreenSharingFrame(header: header, data: Data(repeating: 1, count: 4)))
        XCTAssertEqual(box.reception().0, 2)
        XCTAssertNotNil(box.reception().1)
        XCTAssertEqual(box.takeFrames().count, 1)
        XCTAssertEqual(box.reception().0, 2)
        XCTAssertEqual(ScreenSharingMailbox().reception().0, 0)
    }

    func testFrameRateUsesActualElapsedTimeAndIdleFallsToZero() {
        var meter = ScreenSharingPerformanceMeter(now: 10)
        for _ in 0..<15 { meter.presentedFrame() }
        XCTAssertEqual(meter.sample(now: 10.5).framesPerSecond, 30)
        XCTAssertEqual(meter.sample(now: 12).framesPerSecond, 0)
    }

    func testTrafficExpiresInsteadOfDisplayingFrozenRates() {
        var meter = ScreenSharingPerformanceMeter(now: 0)
        meter.receiveTraffic(received: 125_000, sent: 25_000, now: 0.5)
        let first = meter.sample(now: 1)
        XCTAssertEqual(first.receiveBytesPerSecond, 125_000)
        XCTAssertEqual(first.sendBytesPerSecond, 25_000)
        XCTAssertNil(meter.sample(now: 3.5).receiveBytesPerSecond)
        meter.receiveTraffic(received: 0, sent: 0, now: 4)
        XCTAssertEqual(meter.sample(now: 5).receiveBytesPerSecond, 0)
    }

    func testInvalidTrafficAndNewSessionDoNotReusePreviousValues() {
        var meter = ScreenSharingPerformanceMeter(now: 0)
        meter.receiveTraffic(received: .infinity, sent: 10, now: 0)
        XCTAssertNil(meter.sample(now: 1).receiveBytesPerSecond)
        meter.receiveTraffic(received: -1, sent: 10, now: 1)
        XCTAssertNil(meter.sample(now: 2).sendBytesPerSecond)
        meter.receiveTraffic(received: 100, sent: 10, now: 2)
        meter.presentedFrame()
        meter = ScreenSharingPerformanceMeter(now: 3)
        let fresh = meter.sample(now: 4)
        XCTAssertEqual(fresh.framesPerSecond, 0)
        XCTAssertNil(fresh.receiveBytesPerSecond)
    }

    func testZeroLengthSamplingDoesNotDiscardFrames() {
        var meter = ScreenSharingPerformanceMeter(now: 10)
        meter.presentedFrame()
        XCTAssertNil(meter.sample(now: 10).framesPerSecond)
        XCTAssertEqual(meter.sample(now: 11).framesPerSecond, 1)
    }
}
