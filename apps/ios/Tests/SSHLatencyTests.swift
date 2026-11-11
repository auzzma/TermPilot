import XCTest
@testable import TermPilot

final class SSHLatencyTests: XCTestCase {
  @MainActor func testLatencyEventsUpdateOnlyTheirSSHSessionAndClearWhenUnavailable() {
    let model = AppModel()
    let first = MobileSession(id: 1, host: [:], kind: "ssh", terminal: "")
    let other = MobileSession(id: 2, host: [:], kind: "ssh", terminal: "")
    let desktop = MobileSession(id: 3, host: [:], kind: "rdp", terminal: "")
    model.sessions = [first, other, desktop]
    first.connected = true; first.status = "已连接"
    for (message, expected) in [("386.4", 386), ("8.8", 9), ("0", 0)] {
      model.receive(MobilePacket(header: ["session": 1, "type": "log", "status": "latency", "message": message], data: Data()))
      XCTAssertEqual(first.latencyMilliseconds, expected)
      XCTAssertNil(other.latencyMilliseconds)
      XCTAssertEqual(first.status, "已连接")
    }
    XCTAssertFalse(desktop.receiveLatency(status: "latency", message: "42"))
    model.receive(MobilePacket(header: ["session": 1, "type": "log", "status": "latency-unavailable"], data: Data()))
    XCTAssertNil(first.latencyMilliseconds)
    XCTAssertTrue(first.connected, "A missed probe must not disconnect a usable terminal")
    XCTAssertNil(model.error)
  }

  func testMalformedLatencyIsNotAValidZeroOrOverflow() {
    for message in ["", " ", "NaN", "inf", "-1", "1e30", "unavailable"] {
      XCTAssertNil(SSHLatency.parse(message))
    }
  }
}
