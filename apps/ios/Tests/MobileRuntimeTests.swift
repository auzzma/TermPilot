import XCTest

@testable import TermPilot

@_silgen_name("tp_mobile_media_probe") private func mediaProbe(
  _ bytes: UnsafePointer<UInt8>, _ count: Int
) -> Int32

final class MobileRuntimeTests: XCTestCase {
  func testNativeHEVC444AndAACELDSBR() throws {
    let path = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "eld-sbr", withExtension: "fixture"))
    let data = try Data(contentsOf: path)
    let result = data.withUnsafeBytes {
      mediaProbe($0.bindMemory(to: UInt8.self).baseAddress!, $0.count)
    }
    XCTAssertEqual(result, 0, "System media decoder must preserve four tiles and valid stereo PCM")
  }

  func testVaultKeepsDataWithInjectedKeyAndNoPlaintextKeyFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 41, count: 32)
    let runtime = try MobileRuntime(directory: root, testKey: key)
    let saved = try await runtime.call([
      "method": "vault.save", "collection": "credentials",
      "item": [
        "id": UUID().uuidString, "label": "测试凭证", "kind": "password", "username": "test",
        "password": "fixture-only-password",
      ],
    ])
    XCTAssertEqual(saved.object("item").text("label"), "测试凭证")
    runtime.stop()
    let reopened = try MobileRuntime(directory: root, testKey: key)
    defer { reopened.stop() }
    let rows = try await reopened.call(["method": "vault.list", "collection": "credentials"])
    XCTAssertEqual(rows.array("items").first?.text("password"), "fixture-only-password")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("credential.key").path))
    let database = try Data(contentsOf: root.appendingPathComponent("vault.sqlite"))
    XCTAssertNil(database.range(of: Data("fixture-only-password".utf8)))
  }
  func testTerminalUnicodeRepliesAndScrollback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 8, count: 32))
    defer { runtime.stop() }
    let id = try await runtime.call(["method": "terminal.create", "rows": 3, "columns": 40]).text(
      "id")
    let result = try await runtime.call([
      "method": "terminal.feed", "id": id,
      "data": Data("中文\r\n\u{1b}[6n".utf8).base64EncodedString(),
    ])
    XCTAssertEqual(Data(base64Encoded: result.text("reply")), Data("\u{1b}[2;1R".utf8))
    let snapshot = try await runtime.call(["method": "terminal.snapshot", "id": id])
    XCTAssertEqual(snapshot.array("cells").first?.text("text"), "中")
    _ = try await runtime.call(["method": "terminal.close", "id": id])
  }
  func testRejectsDesktopCommandProxy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 9, count: 32))
    defer { runtime.stop() }
    do {
      _ = try await runtime.call([
        "method": "session.open", "protocol": "ssh",
        "command": [
          "type": "connect", "config": ["proxy": ["type": "command", "command": "invalid-test"]],
        ],
      ])
      XCTFail("Mobile must not start desktop proxy executables")
    } catch { XCTAssertTrue(error.localizedDescription.contains("proxies")) }
  }
  func testManagementArgumentQuoting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 10, count: 32))
    defer { runtime.stop() }
    do {
      _ = try await runtime.call([
        "method": "mobile.serverTool", "operation": "dockerRemove", "value": "--all",
      ])
      XCTFail("Docker options must not become container names")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid")) }
  }
}
