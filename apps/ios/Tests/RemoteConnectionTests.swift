import XCTest

@testable import TermPilot

final class RemoteConnectionTests: XCTestCase {
  func testPinnedRDPReceivesDesktopFrame() async throws {
    let fixture = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("mobile-remote-fixture.json")
    guard FileManager.default.fileExists(atPath: fixture.path) else {
      throw XCTSkip("No authorized pinned RDP fixture")
    }
    defer { try? FileManager.default.removeItem(at: fixture) }
    let source = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! JSON
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rdp-test-\(UUID().uuidString)")
    let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 71, count: 32))
    defer {
      runtime.stop()
      try? FileManager.default.removeItem(at: root)
    }
    var command = source.object("rdp")
    command["cacheDirectory"] = root.appendingPathComponent("files").path
    XCTAssertEqual(command.text("certificateSHA256").count, 64)
    let frame = expectation(description: "Receive a decoded RDP desktop frame")
    let capture = RemoteCapture(frame)
    runtime.start { packet in capture.receive(packet) }
    let session = try await runtime.call([
      "method": "session.open", "protocol": "rdp", "command": command,
    ]).number("session")
    await fulfillment(of: [frame], timeout: 45)
    XCTAssertNil(capture.error)
    XCTAssertGreaterThan(capture.bytes, 0)
    _ = try await runtime.call(["method": "session.close", "session": session])
  }
}
private final class RemoteCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let expectation: XCTestExpectation
  private var finished = false
  private(set) var error: String?
  private(set) var bytes = 0
  init(_ expectation: XCTestExpectation) { self.expectation = expectation }
  func receive(_ packet: MobilePacket) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    let kind = packet.header.text("kind", packet.header.text("type"))
    if ["error", "certificate", "sessionEnded"].contains(kind) {
      error = "RDP stopped at \(kind): \(packet.header.text("code"))"
      finished = true
      expectation.fulfill()
    }
    if kind == "frame" {
      if packet.header.text("pixelFormat") != "bgrx"
        || packet.data.count < packet.header.number("width") * packet.header.number("height") * 4
      {
        error = "Invalid RDP frame"
      }
      bytes = packet.data.count
      finished = true
      expectation.fulfill()
    }
  }
}
