import XCTest
@testable import TermPilotRemoteDiagnostics
final class RemoteVideoDiagnosticsTests: XCTestCase {
    func testEngineStatisticsAreMappedWithoutSensitiveExtras() throws {
        let media = try JSONDecoder().decode(RemoteMediaDiagnostics.self, from: Data(#"{"videoCodec":"H.264","videoPackets":1234,"decodeErrors":40,"audioDecodeErrors":3,"lastVideoDecodeError":-1009,"decodeMicros":18000,"decodeCalls":3,"maxDecodeMicros":8000,"maxQueueMicros":10000,"password":"secret","hostname":"private"}"#.utf8))
        let report = media.report()
        XCTAssertTrue(report.contains("Video packets: 1234"))
        XCTAssertTrue(report.contains("Video errors: 37 · Last code: -1009 · Audio errors: 3"))
        XCTAssertTrue(report.contains("6.00 ms avg · 8.00 ms max · Queue wait: 10.00 ms max"))
        XCTAssertFalse(report.contains("secret")); XCTAssertFalse(report.contains("private"))
        XCTAssertTrue(report.contains("Dropped: —"), "An absent statistic is not a measured zero")
    }
    func testReceiveAndPresentationAreIndependentAndAgesAdvanceWhileStalled() {
        var d = RemoteVideoDiagnostics()
        d.received(now: 10); d.received(now: 11); d.rendered(now: 12)
        let report = d.report(platform: "test", mode: "VNC", resolution: "1 × 1", fps: 0,
                              received: nil, sent: nil, now: 16)
        XCTAssertTrue(report.contains("接收画面: 2 · 5.0 s"))
        XCTAssertTrue(report.contains("绘制画面: 1 · 4.0 s"))
        XCTAssertFalse(report.contains("Decode errors"))
        XCTAssertNil(RemoteVideoDiagnostics().lastFrameAt)
    }
    func testNoFramesOrDecodeCallsRemainUnavailable() throws {
        let d = RemoteVideoDiagnostics()
        XCTAssertTrue(d.report(platform:"test", mode:"RDP", resolution:"—", fps:nil, received:nil, sent:nil, now:20).contains("0 · 暂无"))
        let media = try JSONDecoder().decode(RemoteMediaDiagnostics.self, from: Data(#"{"decodeCalls":0,"decodeMicros":0}"#.utf8))
        XCTAssertTrue(media.report().contains("Decode time: — ms avg"))
    }
}
