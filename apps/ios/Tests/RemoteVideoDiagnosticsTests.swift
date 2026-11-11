import XCTest
@testable import TermPilot
final class RemoteVideoDiagnosticsTests: XCTestCase {
  @MainActor func testMediaEventsReachTheCorrectSessionBeforeFirstFrame() {
    let model = AppModel()
    let first = MobileSession(id: 901, host: ["mode":"highPerformance"], kind: "screen", terminal: "")
    let other = MobileSession(id: 902, host: [:], kind: "rdp", terminal: "")
    model.sessions = [first, other]
    model.receive(MobilePacket(header: ["session":901,"kind":"mediaDiagnostics","videoCodec":"H.264","videoPackets":17,"decodeErrors":2,"audioDecodeErrors":0], data: Data()))
    XCTAssertTrue(first.videoDiagnosticsReport().contains("Video packets: 17"))
    XCTAssertTrue(first.videoDiagnosticsReport().contains("Video errors: 2"))
    XCTAssertFalse(other.videoDiagnosticsReport().contains("Video packets"))
    XCTAssertEqual(first.frameRevision, 0)
    XCTAssertFalse(first.connected)
  }
  @MainActor func testReceivedFrameDoesNotPretendItWasRendered() {
    let model = AppModel()
    let session = MobileSession(id: 903, host: ["mode":"standardVNC"], kind: "screen", terminal: "")
    session.connected = true // avoid recording connection history in the fixture
    model.sessions = [session]
    model.receive(MobilePacket(header: ["session":903,"kind":"frame","width":1,"height":1,"tile":0], data: Data([0,0,0,0])))
    XCTAssertEqual(session.videoDiagnostics.receivedFrames, 1)
    XCTAssertEqual(session.videoDiagnostics.renderedFrames, 0)
    XCTAssertNotNil(session.videoDiagnostics.lastFrameAt)
  }
}
