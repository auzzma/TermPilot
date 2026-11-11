import XCTest

@testable import TermPilot

final class AppFlowTests: XCTestCase {
  @MainActor func testNativeModelConnectionAndTransfer() async throws {
    let fixture = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("mobile-fixture.json")
    guard FileManager.default.fileExists(atPath: fixture.path) else {
      throw XCTSkip("No authorized live-host fixture")
    }
    defer { try? FileManager.default.removeItem(at: fixture) }
    let source = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? JSON)
    var host = try LiveTestFixture.host(source, role: "ssh")
    host["connectionKind"] = "ssh"
    host["label"] = "移动原生界面验收"
    let model = AppModel()
    await model.start()
    XCTAssertTrue(model.ready)
    let known = model.runtime!.directory.appendingPathComponent("known_hosts")
    let original = try? Data(contentsOf: known)
    defer {
      if let original {
        try? original.write(to: known)
      } else {
        try? FileManager.default.removeItem(at: known)
      }
    }
    try Data(source.text("knownHosts").utf8).write(to: known)
    _ = try await model.openAISettings()
    try await model.connect(host)
    let s = try XCTUnwrap(model.current)
    let until = Date().addingTimeInterval(30)
    while (!s.filesReady || !s.execReady) && Date() < until {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(s.filesReady && s.execReady)
    try await model.openAI(s)
    XCTAssertFalse(s.conversation.text("id").isEmpty)
    XCTAssertEqual(s.aiScope, s.conversation.text("scope"))
    let root = model.runtime!.directory.appendingPathComponent(
      "Transfers/ui-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("native-中文.bin")
    try Data(repeating: 31, count: 64 * 1024 * 1024).write(to: input)
    let remote =
      try await model.files(s, ["action": "realpath", "path": "."]).text("path")
      + "/TermPilot-native-" + UUID().uuidString + ".bin"
    do {
      let upload = Task { try await model.transfer(s, upload: true, local: input, remote: remote) }
      let deadline = Date().addingTimeInterval(10)
      while s.transfers.values.first?.number("transferred") ?? 0 == 0, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let transferID = try XCTUnwrap(s.transfers.keys.first)
      try await model.controlTransfer(s, id: transferID, action: "pause")
      XCTAssertTrue(
        model.transferHistory.contains {
          $0.text("id") == transferID && $0.text("status") == "paused"
        })
      try await model.controlTransfer(s, id: transferID, action: "resume")
      try await upload.value
      XCTAssertTrue(
        model.transferHistory.contains {
          $0.text("name") == input.lastPathComponent && $0.text("status") == "completed"
        })
      XCTAssertTrue(
        (model.records["history"] ?? []).contains {
          $0.text("id") == s.host.text("sessionID") && $0["succeeded"] as? Bool == true
        })
      _ = try await model.files(s, ["action": "delete", "path": remote])
      try await model.close(s)
    } catch {
      _ = try? await model.files(s, ["action": "delete", "path": remote])
      try? await model.close(s)
      throw error
    }
  }
}
