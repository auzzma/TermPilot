import CryptoKit
import XCTest

@testable import TermPilot

private actor HostKeyEvents {
  var items: [JSON] = []
  func add(_ value: JSON) { items.append(value) }
  func next() -> JSON? { items.isEmpty ? nil : items.removeFirst() }
}

final class HostKeyPersistenceTests: XCTestCase {
  func testFirstApprovalPersistsAndReconnectDoesNotPrompt() async throws {
    let fixture = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("mobile-fixture.json")
    guard FileManager.default.fileExists(atPath: fixture.path) else {
      throw XCTSkip("No authorized live-host fixture")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-key-\(UUID())")
    defer {
      try? FileManager.default.removeItem(at: fixture)
      try? FileManager.default.removeItem(at: root)
    }
    let source = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! JSON
    let saved = try LiveTestFixture.host(source, role: "tools")
    let host = saved.text("hostname"), port = saved.number("port", 22)
    let pattern = port == 22 ? host : "[\(host)]:\(port)"
    // Only approve keys already pinned in the authorized desktop configuration.
    let keys = try XCTUnwrap(source.object("verifiedHostKeys")[pattern] as? [String])
    var approved: [String: String] = [:]
    for key in keys {
      let digest = SHA256.hash(data: try XCTUnwrap(Data(base64Encoded: key)))
      approved["SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")] = key
    }
    XCTAssertFalse(approved.isEmpty)
    let known = root.appendingPathComponent("known_hosts")
    XCTAssertFalse(FileManager.default.fileExists(atPath: known.path))
    for attempt in 0..<2 {
      let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 77, count: 32))
      defer { runtime.stop() }
      let events = HostKeyEvents()
      runtime.start { packet in Task { await events.add(packet.header) } }
      var config = saved
      config["knownHostsFile"] = known.path
      config["autoAcceptHostKeys"] = false
      let session = try await runtime.call([
        "method": "session.open", "protocol": "ssh",
        "command": ["type": "connect", "config": config, "cols": 80, "rows": 24],
      ]).number("session")
      func send(_ command: JSON) async throws {
        _ = try await runtime.call(["method": "session.send", "session": session, "command": command])
      }
      var prompts = 0
      func wait(_ predicate: (JSON) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
          guard let event = await events.next() else {
            try await Task.sleep(for: .milliseconds(20)); continue
          }
          guard event.number("session") == session else { continue }
          if event.text("type") == "hostKeyPrompt" {
            let detail = event.object("detail")
            guard attempt == 0, detail.text("hostPattern") == pattern,
              approved[detail.text("fingerprint")] != nil, detail["hasHostPattern"] as? Bool == false
            else { throw MobileError(message: "Unexpected or unapproved SSH host key") }
            prompts += 1
            try await send(["type": "hostKeyResponse", "promptID": event.text("promptID"), "accepted": true])
          }
          if ["error", "sessionEnded", "credentialPrompt"].contains(event.text("type")) {
            throw MobileError(message: "SSH first-use/reconnect failed: \(event.text("message"))")
          }
          if predicate(event) { return }
        }
        throw MobileError(message: "Host-key test timed out")
      }
      try await wait { $0.text("type") == "log" && $0.text("status") == "connected" }
      XCTAssertEqual(prompts, attempt == 0 ? 1 : 0)
      let persisted = try String(contentsOf: known, encoding: .utf8)
      XCTAssertTrue(approved.values.contains { persisted.contains($0) })
      try await send(["type": "sftpOpen", "config": ["fileProtocol": "sftp"]])
      try await wait { $0.text("type") == "sftpReady" }
      _ = try await runtime.call(["method": "session.close", "session": session])
    }
    print("iOS first SSH approval, known_hosts persistence, runtime reopen and SFTP passed")
  }
}
