import XCTest

@testable import TermPilot

@_silgen_name("tp_mobile_media_probe") private func mediaProbe(
  _ bytes: UnsafePointer<UInt8>, _ count: Int
) -> Int32

final class MobileRuntimeTests: XCTestCase {
  @MainActor
  func testRawBandsKeepUnchangedPixelsAndResetOnResize() {
    func band(_ tile: Int, _ generation: Int, _ byte: UInt8, desktop: Int = 130) -> MobilePacket {
      let y = tile*64, height = min(64,desktop-y)
      return MobilePacket(header:["kind":"frame","tile":tile,"width":2,"height":height,"yStride":8,
        "pixelFormat":"bgrx","originY":y,"desktopWidth":2,"desktopHeight":desktop,"rawGeneration":generation],data:Data(repeating:byte,count:height*8))
    }
    let session = MobileSession(id:42,host:[:],kind:"screen",terminal:"fixture")
    XCTAssertTrue(session.acceptFrame(band(0,1,1)))
    XCTAssertTrue(session.acceptFrame(band(2,1,2)))
    XCTAssertTrue(session.acceptFrame(band(0,1,3)))
    XCTAssertEqual(session.frames.count,2)
    XCTAssertEqual(session.frames[2]?.data.first,2)
    XCTAssertEqual(session.desktopSize,CGSize(width:2,height:130))
    XCTAssertTrue(session.acceptFrame(band(0,2,4,desktop:64)))
    XCTAssertFalse(session.acceptFrame(band(2,1,5)))
    XCTAssertEqual(session.frames.count,1)
    XCTAssertEqual(session.desktopSize,CGSize(width:2,height:64))
    let good = band(2,1,6)
    var invalid=good.header;invalid["originY"]=127
    XCTAssertNil(RawScreenLayout(MobilePacket(header:invalid,data:good.data)))
  }

  @MainActor
  func testAutomationWarningIsSessionScopedAndDoesNotBlockChatOrConnection() {
    let model = AppModel()
    let session = MobileSession(id: 42, host: ["id": UUID().uuidString, "label": "Fixture"], kind: "ssh", terminal: "fixture")
    let other = MobileSession(id: 43, host: ["id": UUID().uuidString, "label": "Other"], kind: "ssh", terminal: "other")
    session.ai = 100
    session.connected = true
    model.sessions = [session, other]
    model.receive(MobilePacket(header: ["session": 100, "type": "automationError", "sessionId": "42", "message": "Fixture queue failure"], data: Data()))
    XCTAssertEqual(session.automationWarning, "Fixture queue failure")
    XCTAssertNil(other.automationWarning)
    XCTAssertNil(model.error)
    XCTAssertTrue(session.connected)
    model.receive(MobilePacket(header: ["session": 100, "type": "automationError", "sessionId": "43", "message": "Wrong target"], data: Data()))
    XCTAssertEqual(session.automationWarning, "Fixture queue failure")
    model.receive(MobilePacket(header: ["session": 100, "type": "delta", "text": "still chatting"], data: Data()))
    XCTAssertEqual(session.partial, "still chatting")
    session.automationWarning = nil
    XCTAssertNil(session.automationWarning)
  }

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
