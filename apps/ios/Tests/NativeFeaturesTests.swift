import Darwin
import XCTest

@testable import TermPilot

final class NativeFeaturesTests: XCTestCase {
  func testImportedInlineProxyCanBeChangedToDirectOrProfile() {
    var host: JSON = ["proxyProfileID":"old", "proxyConfiguration":["type":"socks5", "host":"127.0.0.1", "port":7890]]
    XCTAssertEqual(HostProxySelection.value(host), HostProxySelection.inline)
    HostProxySelection.select("", in: &host)
    XCTAssertTrue(host["proxyConfiguration"] is NSNull)
    XCTAssertTrue(host["proxyProfileID"] is NSNull)
    XCTAssertEqual(HostProxySelection.value(host), "")
    HostProxySelection.select("new-profile", in: &host)
    XCTAssertTrue(host["proxyConfiguration"] is NSNull)
    XCTAssertEqual(host.text("proxyProfileID"), "new-profile")
  }
  func testAppleMetadataExportDetectionPreservesOriginal() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("content".utf8).write(to: file)
    XCTAssertFalse(AppleFileMetadata.needsConfirmation([file]))
    let metadata = Data(repeating: 7, count: 32)
    let result = metadata.withUnsafeBytes {
      setxattr(file.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0)
    }
    XCTAssertEqual(result, 0)
    XCTAssertTrue(AppleFileMetadata.needsConfirmation([file]))
    XCTAssertEqual(try Data(contentsOf: file), Data("content".utf8))
  }
  func testShortcutOrderAndFunctionKeys() {
    let keys = TerminalKey.ordered("F12,Tab,invalid,F1,Tab")
    XCTAssertEqual(keys.map(\.name), ["F12", "Tab", "F1"])
    XCTAssertEqual(keys.first?.text, "\u{1b}[24~")
    XCTAssertEqual(keys.last?.text, "\u{1b}OP")
    XCTAssertEqual(keys.last?.code, 0xffbe)
  }
  func testScriptReorderUsesSharedVault() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 11, count: 32))
    defer { runtime.stop() }
    let ids = [UUID().uuidString, UUID().uuidString]
    for (index, id) in ids.enumerated() {
      _ = try await runtime.call([
        "method": "vault.save", "collection": "scripts",
        "item": ["id": id, "title": "script-\(index)", "body": "printf ok", "shell": "/bin/sh"],
      ])
    }
    _ = try await runtime.call([
      "method": "vault.reorder", "collection": "scripts", "ids": Array(ids.reversed()),
    ])
    let rows = try await runtime.call(["method": "vault.list", "collection": "scripts"]).array(
      "items")
    XCTAssertEqual(rows.map { $0.text("id") }, Array(ids.reversed()))
    XCTAssertEqual(rows.first?.text("body"), "printf ok")
  }
}
