import XCTest
@testable import TermPilot

/// Opt-in device acceptance: use only the selected host's existing configuration.
/// Session state/history goes to a temporary vault, never the user's synced vault.
final class ConfiguredConnectionTests: XCTestCase {
  @MainActor func testSelectedHostWithConfiguredProxyAndDirectConnection() async throws {
    let fixture = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("connection-check.json")
    guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("No selected-host acceptance fixture") }
    defer { try? FileManager.default.removeItem(at: fixture) }
    let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? JSON)
    let source = try MobileRuntime()
    let hosts = try await source.call(["method":"vault.list", "collection":"hosts"]).array("items")
      .filter { $0.text("hostname") == input.text("host") }
    let credentials = try await source.call(["method":"vault.list", "collection":"credentials"]).array("items")
    let proxies = try await source.call(["method":"vault.list", "collection":"proxies"]).array("items")
    var candidates: [JSON] = []
    for kind in ["ssh", "rdp"] {
      guard var host = hosts.first(where: { $0.text("connectionKind", "ssh") == kind }) else {
        XCTFail("Selected host has no \(kind) configuration"); continue
      }
      if kind == "rdp", let profile = try await source.call(["method":"vault.get", "collection":"screenSharing", "id":host.text("id")])["item"] as? JSON {
        host.merge(profile) { _, value in value }
      }
      host["certificateSHA256"] = input["certificateSHA256"]
      candidates.append(host)
    }
    source.stop()
    for host in candidates {
      for direct in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 94, count: 32))
        let model = AppModel(); model.runtime = runtime
        model.records = ["credentials":credentials, "proxies":proxies]
        runtime.start { packet in Task { @MainActor in model.receive(packet) } }
        try input.text("knownHosts").write(to: root.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        var candidate = host
        if direct { candidate["proxyProfileID"] = NSNull(); candidate["proxyConfiguration"] = NSNull() }
        do {
          try await model.connect(candidate)
          let session = try XCTUnwrap(model.current)
          let proxy = session.host.object("proxy")
          print("Connection acceptance: \(session.protocolKind), \(direct ? "direct" : "configured"), proxy=\(proxy.text("host")):\(proxy.number("port"))")
          let deadline = Date().addingTimeInterval(35)
          while !session.connected && model.error == nil && model.interaction == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
          }
          print("Connection acceptance: connected=\(session.connected), error=\(model.error ?? "none"), prompt=\(model.interaction?.event.text("type", model.interaction?.event.text("kind") ?? "") ?? "none")")
          if direct { XCTAssertTrue(session.connected, model.error ?? "Connection did not become ready") }
          try await model.close(session)
        } catch { XCTFail(error.localizedDescription) }
        runtime.stop()
        try? FileManager.default.removeItem(at: root)
      }
    }
  }
}
