import XCTest

@testable import TermPilot

final class ScreenConnectionTests: XCTestCase {
  func testVNCAndAppleHighPerformanceReceiveFrames() async throws {
    let fixture = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("mobile-screen-fixture.json")
    guard FileManager.default.fileExists(atPath: fixture.path) else {
      throw XCTSkip("No authorized screen fixture")
    }
    defer { try? FileManager.default.removeItem(at: fixture) }
    let source = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! JSON
    for (mode, codec) in [("standardVNC","h264"),("highPerformance","h264"),("highPerformance","h265")] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "screen-test-" + UUID().uuidString)
      let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 43, count: 32))
      defer {
        runtime.stop()
        try? FileManager.default.removeItem(at: root)
      }
      var command = source.object("screen")
      command["mode"] = mode
      command["videoCodec"] = codec
      command["lockDirectory"] = root.appendingPathComponent("lock").path
      let expected = expectation(description: "Screen frames: " + mode)
      let capture = ScreenCapture(expected, tiles: mode == "highPerformance" && codec == "h265" ? 4 : 1)
      runtime.start { capture.receive($0) }
      let s = try await runtime.call([
        "method": "session.open", "protocol": "screen", "command": command,
      ]).number("session")
      await fulfillment(of: [expected], timeout: 60)
      XCTAssertNil(capture.error)
      XCTAssertEqual(capture.seen.count, mode == "highPerformance" && codec == "h265" ? 4 : 1)
      _ = try await runtime.call(["method": "session.close", "session": s])
      runtime.stop()
      print("Mobile screen result: \(mode) tiles=\(capture.seen.count)")
      try await Task.sleep(for: .seconds(2))
    }
  }
}
private final class ScreenCapture: @unchecked Sendable {
  let lock = NSLock()
  let expectation: XCTestExpectation
  let tiles: Int
  var seen = Set<Int>()
  var error: String?
  var done = false
  init(_ expectation: XCTestExpectation, tiles: Int) {
    self.expectation = expectation
    self.tiles = tiles
  }
  func receive(_ p: MobilePacket) {
    lock.lock()
    defer { lock.unlock() }
    guard !done else { return }
    let kind = p.header.text("kind", p.header.text("type"))
    if ["error", "disconnected", "sessionEnded"].contains(kind) {
      error = "Screen stopped: " + p.header.text("code", p.header.text("error", kind))
      done = true
      expectation.fulfill()
    }
    if kind == "frame", !p.data.isEmpty {
      seen.insert(p.header.number("tile"))
      if seen.count == tiles {
        done = true
        expectation.fulfill()
      }
    }
  }
}
