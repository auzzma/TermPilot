import SwiftUI
import XCTest
@testable import TermPilot

@MainActor final class MobileDesktopControlsTests: XCTestCase {
  func controls() -> MobileDesktopControls {
    let c = MobileDesktopControls(); c.available = { true }; c.keyTimeout = .milliseconds(50); c.resizeTimeout = .milliseconds(50); return c
  }
  func testUnicodePasswordUsesAcknowledgedKeysAndOneReturn() async {
    let c = controls(); var keys:[Int] = []; var kinds:[String] = []
    c.send = { e in
      kinds.append(e.text("kind")); XCTAssertNil(e["password"]); XCTAssertNil(e["text"])
      if e.text("kind") == "credentialKey" { keys.append(e.number("key")); c.receive(["kind":"credentialKeySent","requestID":e.text("requestID")]) }
    }
    await c.login { "A!空🔑é" }
    XCTAssertEqual(keys,[65,33,0x01007a7a,0x0101f511,233,0xff0d])
    XCTAssertEqual(kinds.first,"release"); XCTAssertEqual(kinds.last,"release")
    XCTAssertFalse(c.loginBusy); XCTAssertTrue(c.loginMessage.contains("查看远端登录结果"))
  }
  func testWrongAckAndRepeatedClickCannotAdvanceThenCancellationStopsReturn() async throws {
    let c = controls(); var keys:[JSON] = []; c.keyTimeout = .seconds(2)
    c.send = { if $0.text("kind") == "credentialKey" { keys.append($0) } }
    let task = Task { await c.login { "abc" } }
    try await Task.sleep(for:.milliseconds(20))
    await c.login { XCTFail("Second click must not resolve credentials"); return "wrong" }
    c.receive(["kind":"credentialKeySent","requestID":"stale"])
    XCTAssertEqual(keys.count,1); c.cancelLogin()
    await task.value
    c.receive(["kind":"credentialKeySent","requestID":keys[0].text("requestID")])
    XCTAssertEqual(keys.count,1); XCTAssertFalse(c.loginBusy)
  }
  func testTimeoutAndSendFailureNeverSubmitPartialPassword() async {
    for fail in [false,true] {
      let c = controls(); var keys:[Int] = []
      c.send = { if $0.text("kind") == "credentialKey" { keys.append($0.number("key")); if fail { throw CancellationError() } } }
      await c.login { "secret" }
      XCTAssertEqual(keys,[115]); XCTAssertFalse(c.loginBusy)
      XCTAssertFalse(c.loginMessage.contains("secret"))
    }
  }
  func testCancelDuringCredentialResolutionAndInvalidPasswordSendNoKeys() async throws {
    let c = controls(); var sent = 0
    c.send = { if $0.text("kind") == "credentialKey" { sent += 1 } }
    let task = Task { await c.login { try await Task.sleep(for:.milliseconds(40)); return "secret" } }
    try await Task.sleep(for:.milliseconds(10)); c.cancelLogin(); await task.value
    for password in ["", "line\nreturn", String(repeating:"x",count:1025)] { await c.login { password } }
    XCTAssertEqual(sent,0)
  }
  func testResizeCapabilityRejectionForwardedAndLateAck() async throws {
    let c = controls(); var sent:[JSON] = []; c.send = { sent.append($0) }
    let value = DesktopResolution.presets[0]
    await c.resizeVNC(value); XCTAssertTrue(sent.isEmpty)
    c.receive(["kind":"vncCapabilities","canResize":true]); await c.resizeVNC(value)
    let id = sent[0].text("requestID"); XCTAssertEqual(sent[0].number("width"),1280)
    c.receive(["kind":"vncResizeResult","requestID":"stale","accepted":true]); XCTAssertTrue(c.resizeBusy)
    c.receive(["kind":"vncResizeResult","requestID":id,"pending":true]); XCTAssertTrue(c.resizeBusy)
    await c.resizeVNC(DesktopResolution.presets[1]); XCTAssertEqual(sent.count,1)
    try await Task.sleep(for:.milliseconds(80)); XCTAssertTrue(c.resizeBlocked); XCTAssertFalse(c.resizeBusy)
    c.receive(["kind":"vncResizeResult","requestID":id,"accepted":false,"code":"vncResizeProhibited"])
    XCTAssertFalse(c.resizeBlocked); XCTAssertTrue(c.resizeMessage.contains("不允许"))
    await c.resizeVNC(value); c.receive(["kind":"vncResizeResult","requestID":sent[1].text("requestID"),"accepted":true]); XCTAssertFalse(c.resizeBusy)
    c.receive(["kind":"vncCapabilities","canResize":false]); await c.resizeVNC(value); XCTAssertEqual(sent.count,2)
    c.stop()
  }
  func testHighPerformanceOperationUsesReconnectAndGuardsDuplicateActions() async {
    let c = controls(); var count = 0; c.send = { _ in XCTFail("HP resolution must reconnect") }
    await c.reconnectResolution {
      count += 1
      await c.reconnectResolution { XCTFail("Duplicate reconnect") }
      await c.login { XCTFail("Login during reconnect"); return "secret" }
    }
    XCTAssertEqual(count,1); XCTAssertFalse(c.resizeBusy)
  }
  func fixture() -> (AppModel,MobileSession) {
    let m = AppModel(); let s = MobileSession(id:990,host:["mode":"highPerformance"],kind:"screen",terminal:"")
    s.connected = true; m.sessions = [s]; m.selected = s.id; m.bindDesktopControls(s); return (m,s)
  }
  func testManualInputIsSuppressedAndLifecycleSelectionAndPanelCancel() async throws {
    for reason in ["background","inactive","selection","panel"] {
      let (m,s) = fixture(); var commands:[JSON] = []; m.keyboardFixtureCommand = { commands.append($0) }
      s.desktopControls.keyTimeout = .seconds(2)
      let task = Task { await s.desktopControls.login { "abc" } }
      try await Task.sleep(for:.milliseconds(20))
      try await m.send(s.id,["kind":"pointer","buttons":1]); try await m.send(s.id,["kind":"text","text":"other"])
      switch reason { case "background": m.lifecycle(.background); case "inactive": m.lifecycle(.inactive); case "selection": m.selected = nil; default: s.activePanel = "ai" }
      await task.value
      XCTAssertEqual(commands.filter { $0.text("kind") == "credentialKey" }.count,1)
      XCTAssertFalse(commands.contains { ["pointer","text"].contains($0.text("kind")) })
    }
  }
  func testConnectedAndDesktopSizeEventsUpdateRealGeometry() {
    let (m,s) = fixture()
    for kind in ["connected","desktopSize"] {
      m.receive(MobilePacket(header:["session":990,"kind":kind,"width":2560,"height":1440],data:Data()))
      XCTAssertEqual(s.desktopSize,CGSize(width:2560,height:1440))
      m.receive(MobilePacket(header:["session":990,"kind":kind,"width":0,"height":-1],data:Data()))
      XCTAssertEqual(s.desktopSize,CGSize(width:2560,height:1440))
    }
  }
  func testFreshVaultCredentialEditDeletionAndEndpointChange() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runtime = try MobileRuntime(directory:root,testKey:Data(repeating:71,count:32))
    defer { runtime.stop(); try? FileManager.default.removeItem(at:root) }
    let m = AppModel(); m.runtime = runtime
    let cid = UUID().uuidString, hid = UUID().uuidString
    let source:JSON = ["id":hid,"label":"Fixture","hostname":"fixture.invalid","port":5900,"username":"fixture","connectionKind":"screenSharing","authentication":"password","credentialID":cid]
    func save(_ collection:String,_ item:JSON) async throws { _ = try await m.call(["method":"vault.save","collection":collection,"item":item]) }
    func credential(_ password:String) -> JSON { ["id":cid,"label":"Fixture","kind":"password","username":"fixture","password":password] }
    try await save("credentials",credential("old")); try await save("hosts",source)
    let s = MobileSession(id:990,host:source.merging(["host":"fixture.invalid","mode":"standardVNC","password":"old"]) { _,b in b },kind:"screen",terminal:"")
    s.sourceHost = source; s.savedHost = true
    try await save("credentials",credential("new"))
    let fresh = try await m.freshDesktopConnection(s); XCTAssertEqual(fresh.1.1.text("password"),"new")
    var changed = source; changed["hostname"] = "other.invalid"; try await save("hosts",changed)
    do { _ = try await m.freshDesktopConnection(s); XCTFail("Changed endpoint") } catch {}
    try await save("hosts",source)
    _ = try await m.call(["method":"vault.delete","collection":"credentials","id":cid])
    do { _ = try await m.freshDesktopConnection(s); XCTFail("Deleted credential") } catch {}
    _ = try await m.call(["method":"vault.delete","collection":"hosts","id":hid])
    do { _ = try await m.freshDesktopConnection(s); XCTFail("Deleted host") } catch {}
  }
}
