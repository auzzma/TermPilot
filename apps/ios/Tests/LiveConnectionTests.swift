import CryptoKit
import XCTest

@testable import TermPilot

private actor TestEvents {
  var items: [JSON] = []
  func add(_ value: JSON) { items.append(value) }
  func take(_ predicate: (JSON) -> Bool) -> JSON? {
    guard let index = items.firstIndex(where: predicate) else { return nil }
    return items.remove(at: index)
  }
}

/// Fixtures are supplied to this test app's private cache, never embedded in a build.
final class LiveConnectionTests: XCTestCase {
  func testSSHAndSFTPRoundTripOnAuthorizedHosts() async throws {
    let fixture = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("mobile-fixture.json")
    guard FileManager.default.fileExists(atPath: fixture.path) else {
      throw XCTSkip("No authorized live-host fixture in the simulator cache")
    }
    let source = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! JSON
    defer { try? FileManager.default.removeItem(at: fixture) }
    for saved in source.array("hosts") {
      try await checkHost(
        saved, knownHosts: source.text("knownHosts"),
        largeTransferHost: LiveTestFixture.hostname(source, role: "largeTransfer"),
        largeMiB: min(1024, max(200, source.number("largeMiB", 200))))
    }
  }

  private func checkHost(_ saved: JSON, knownHosts: String, largeTransferHost: String, largeMiB: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mobile-live-\(UUID().uuidString)")
    let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 77, count: 32))
    defer {
      runtime.stop()
      try? FileManager.default.removeItem(at: root)
    }
    let known = root.appendingPathComponent("known_hosts")
    try knownHosts.write(to: known, atomically: true, encoding: .utf8)
    let events = TestEvents()
    runtime.start { packet in Task { await events.add(packet.header) } }
    var config = saved
    config["knownHostsFile"] = known.path
    let opened = try await runtime.call([
      "method": "session.open", "protocol": "ssh", "terminalReplies": true,
      "command": ["type": "connect", "config": config, "cols": 80, "rows": 24],
    ])
    var session = opened.number("session")
    func send(_ command: JSON) async throws {
      _ = try await runtime.call(["method": "session.send", "session": session, "command": command])
    }
    func wait(_ predicate: (JSON) -> Bool) async throws -> JSON {
      let deadline = Date().addingTimeInterval(300)
      while Date() < deadline {
        if let rejected = await events.take({
          Int($0.number("session")) == session
            && ["hostKeyPrompt", "credentialPrompt", "sessionEnded", "error"].contains(
              $0.text("type"))
        }) {
          // Never accept unknown keys or log secret-bearing configuration in a test failure.
          throw MobileError(
            message: "Live SSH stopped at \(rejected.text("type")): \(rejected.text("message"))")
        }
        if let item = await events.take(predicate) { return item }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw MobileError(message: "Live SSH event timed out")
    }
    _ = try await wait { $0.text("type") == "log" && $0.text("status") == "connected" }
    try await send(["type": "sftpOpen", "config": ["fileProtocol": "sftp"]])
    _ = try await wait { $0.text("type") == "sftpReady" }
    func files(_ args: JSON) async throws -> JSON {
      let id = UUID().uuidString
      var request = args
      request["id"] = id
      try await send(["type": "sftpRequest", "channel": "files", "request": request])
      let response = try await wait {
        $0.text("type") == "sftpResponse" && $0.object("message").text("id") == id
          && $0.object("message")["ok"] != nil
      }.object("message")
      guard response["ok"] as? Bool == true else {
        throw MobileError(
          message: "Live SFTP \(args.text("action")) failed: \(response.text("error"))")
      }
      return response.object("result")
    }
    let home = try await files(["action": "realpath", "path": "."]).text("path")
    XCTAssertFalse(home.isEmpty)
    let folder = home + "/TermPilot-mobile-test-" + UUID().uuidString
    _ = try await files(["action": "mkdir", "path": folder])
    do {
      let blocks = saved.text("hostname") == largeTransferHost ? largeMiB : 2
      let block = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
      let input = root.appendingPathComponent("upload-中文.bin")
      let output = root.appendingPathComponent("download-中文.bin")
      FileManager.default.createFile(atPath: input.path, contents: nil)
      let writer = try FileHandle(forWritingTo: input)
      for _ in 0..<blocks { try writer.write(contentsOf: block) }
      try writer.close()
      let checkpoint = root.appendingPathComponent("checkpoints").path
      let upload: JSON = [
        "action": "upload", "localPath": input.path, "remotePath": folder + "/中文.bin",
        "overwrite": false, "resumeDirectory": checkpoint,
      ]
      if blocks >= 200 {
        var request = upload
        request["id"] = "interrupt-upload"
        try await send(["type": "sftpRequest", "channel": "files", "request": request])
        _ = try await wait {
          $0.text("type") == "sftpResponse" && $0.object("message").text("event") == "progress"
            && $0.object("message").number("transferred") > 2 * 1024 * 1024
        }
        _ = try await runtime.call(["method": "session.close", "session": session])
        try await Task.sleep(for: .seconds(1))
        session = try await runtime.call([
          "method": "session.open", "protocol": "ssh", "terminalReplies": true,
          "command": ["type": "connect", "config": config, "cols": 80, "rows": 24],
        ]).number("session")
        _ = try await wait {
          $0.number("session") == session && $0.text("type") == "log"
            && $0.text("status") == "connected"
        }
        try await send(["type": "sftpOpen", "config": ["fileProtocol": "sftp"]])
        _ = try await wait { $0.number("session") == session && $0.text("type") == "sftpReady" }
        let state = try FileManager.default.contentsOfDirectory(
          at: URL(fileURLWithPath: checkpoint), includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" }
        let stored =
          try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(state))) as! JSON
        XCTAssertGreaterThan(stored.number("offset"), 0)
        // Changed sources must not be joined to the retained prefix.
        let edit = try FileHandle(forWritingTo: input)
        try edit.write(contentsOf: Data([99]))
        try edit.close()
        do {
          _ = try await files(upload)
          XCTFail("Changed source must reject resume")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Source changed")) }
        let restore = try FileHandle(forWritingTo: input)
        try restore.write(contentsOf: Data([0]))
        try restore.close()
      }
      _ = try await files(upload)
      _ = try await files([
        "action": "rename", "oldPath": folder + "/中文.bin", "newPath": folder + "/renamed.bin",
      ])
      let download: JSON = [
        "action": "download", "localPath": output.path, "remotePath": folder + "/renamed.bin",
        "overwrite": false,
        "resumeDirectory": root.appendingPathComponent("download-checkpoints").path,
      ]
      _ = try await files(download)
      func digest(_ path: URL) throws -> SHA256.Digest {
        let f = try FileHandle(forReadingFrom: path)
        defer { try? f.close() }
        var h = SHA256()
        while let chunk = try f.read(upToCount: 1024 * 1024), !chunk.isEmpty {
          h.update(data: chunk)
        }
        return h.finalize()
      }
      XCTAssertEqual(try digest(input), try digest(output))
      do {
        _ = try await files(download)
        XCTFail("Existing output must not be replaced")
      } catch { XCTAssertTrue(error.localizedDescription.contains("exists")) }
      let sourceFolder = root.appendingPathComponent("folder-中文")
      let targetFolder = root.appendingPathComponent("folder-download")
      try FileManager.default.createDirectory(
        at: sourceFolder.appendingPathComponent("empty"), withIntermediateDirectories: true)
      try Data().write(to: sourceFolder.appendingPathComponent("zero.txt"))
      try block.write(to: sourceFolder.appendingPathComponent("数据.bin"))
      _ = try await files([
        "action": "upload", "localPath": sourceFolder.path, "remotePath": folder + "/folder-中文",
        "overwrite": false,
      ])
      _ = try await files([
        "action": "download", "localPath": targetFolder.path, "remotePath": folder + "/folder-中文",
        "overwrite": false,
      ])
      XCTAssertEqual(
        try digest(sourceFolder.appendingPathComponent("数据.bin")),
        try digest(targetFolder.appendingPathComponent("数据.bin")))
      XCTAssertEqual(try Data(contentsOf: targetFolder.appendingPathComponent("zero.txt")).count, 0)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: targetFolder.appendingPathComponent("empty").path))
      print("Mobile SSH/SFTP \(blocks) MiB SHA-256 roundtrip passed: \(saved.text("hostname"))")
      _ = try await files(["action": "delete", "path": folder])
    } catch {
      _ = try? await files(["action": "delete", "path": folder])
      throw error
    }
    _ = try await runtime.call(["method": "session.close", "session": session])
  }
}
