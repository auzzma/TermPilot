import XCTest
@testable import TermPilot

final class DataSyncTests: XCTestCase {
  func testDuplicateDraftAndSyncProgressAcrossMobileBridge() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-progress-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try MobileRuntime(directory: root.appendingPathComponent("device"), testKey: Data(repeating: 27, count: 32))
    defer { runtime.stop() }
    _ = try await runtime.call(["method":"sync.configure", "provider":["kind":"folder", "path":root.appendingPathComponent("cloud").path], "passphrase":"test-copy-progress-key", "confirmed":true])
    let original = try await runtime.call(["method":"vault.save", "collection":"hosts", "item":["label":"Original", "hostname":"fixture.invalid", "port":5900, "connectionKind":"screenSharing", "authentication":"password", "username":"test"], "screenSharingProfile":["mode":"highPerformance", "username":"test", "password":"fixture-secret", "port":5900, "audio":false]]).object("item")
    let draft = try await runtime.call(["method":"vault.host.duplicateDraft", "id":original["id"]!])
    let before = try await runtime.call(["method":"vault.list", "collection":"hosts"]).array("items")
    XCTAssertEqual(before.count, 1)
    var copy = draft.object("item")
    XCTAssertNotEqual(copy.text("id"), original.text("id"))
    XCTAssertNil(copy["updatedAt"])
    copy["label"] = "Edited copy"
    _ = try await runtime.call(["method":"vault.save", "collection":"hosts", "item":copy, "screenSharingProfile":draft.object("screenSharingProfile")])
    _ = try await runtime.call(["method":"sync.run"])
    let progress = try await runtime.call(["method":"sync.progress"])
    XCTAssertEqual(progress.text("phase"), "completed")
    XCTAssertEqual(progress.number("percent"), 100)
    XCTAssertGreaterThan(progress.number("uploadedBytes"), 0)
    XCTAssertEqual(progress.number("uploadedBytes"), progress.number("verifiedBytes"))
    let source = try await runtime.call(["method":"vault.get", "collection":"hosts", "id":original["id"]!]).object("item")
    XCTAssertEqual(source.text("label"), "Original")
    let profile = try await runtime.call(["method":"vault.get", "collection":"screenSharing", "id":copy["id"]!]).object("item")
    XCTAssertEqual(profile.text("mode"), "highPerformance")
    XCTAssertEqual(profile["audio"] as? Bool, false)
  }

  func testQRCodeFramesAndInvalidInviteThroughMobileBridge() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("invite-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let runtime=try MobileRuntime(directory:root,testKey:Data(repeating:17,count:32));defer{runtime.stop()}
    let result=try await runtime.call(["method":"sync.qr.decode","width":640,"height":480,"pixels":Data(repeating:255,count:640*480).base64EncodedString()])
    XCTAssertTrue(result["code"] is NSNull)
    do {_ = try await runtime.call(["method":"sync.invite.preview","passphrase":"bridge-test-key-123","code":"TP-SYNC:2:unsupported"]);XCTFail("Invalid invitation accepted")}catch{}
    let status=try await runtime.call(["method":"sync.status"])
    XCTAssertEqual(status.array("profiles").count,0)
  }

  func testMobileKeychainStyleKeyAndTwoOfflineReplicasConverge() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let a=try MobileRuntime(directory:root.appendingPathComponent("A"),testKey:Data(repeating:17,count:32))
    let b=try MobileRuntime(directory:root.appendingPathComponent("B"),testKey:Data(repeating:29,count:32))
    defer {a.stop();b.stop()}
    let library=UUID().uuidString
    for (index,runtime) in [a,b].enumerated() {
      _ = try await runtime.call(["method":"sync.configure","provider":["kind":"folder","path":root.appendingPathComponent("cloud").path],"library":library,"passphrase":"simulator-fixture-passphrase","confirmed":true,"scopes":["configuration","preferences"]])
      _ = try await runtime.call(["method":"vault.save","collection":"hosts","item":["label":"mobile-\(index)","hostname":"fixture.invalid","port":22,"connectionKind":"ssh","username":"test","authentication":"password","password":"never-published"]])
    }
    _ = try await a.call(["method":"sync.preferences","values":["theme":"light"]])
    _ = try await a.call(["method":"sync.run"])
    _ = try await b.call(["method":"sync.run"])
    let result=try await a.call(["method":"sync.run"])
    XCTAssertEqual(result.object("preferences").text("theme"),"light")
    for runtime in [a,b] {
      let rows=try await runtime.call(["method":"vault.list","collection":"hosts"]).array("items")
      XCTAssertEqual(rows.count,2)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("A/credential.key").path))
  }
  func testMobilePasswordChangePreservesPendingPeer() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("rekey-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let a=try MobileRuntime(directory:root.appendingPathComponent("A"),testKey:Data(repeating:17,count:32))
    let b=try MobileRuntime(directory:root.appendingPathComponent("B"),testKey:Data(repeating:29,count:32))
    defer {a.stop();b.stop()}
    let library=UUID().uuidString
    for runtime in [a,b] {
      _ = try await runtime.call(["method":"sync.configure","provider":["kind":"folder","path":root.appendingPathComponent("cloud").path],"library":library,"passphrase":"original-test-passphrase","confirmed":true])
      _ = try await runtime.call(["method":"sync.run"])
    }
    _ = try await b.call(["method":"vault.save","collection":"hosts","item":["label":"offline-rekey","hostname":"fixture.invalid","port":22,"username":"test","connectionKind":"ssh","authentication":"password"]])
    _ = try await a.call(["method":"sync.password.begin","oldPassphrase":"original-test-passphrase","newPassphrase":"replacement-test-passphrase","confirmPassphrase":"replacement-test-passphrase","confirmed":true,"clientsUpdated":true])
    let result=try await a.call(["method":"sync.password.resume"])
    XCTAssertEqual(result.object("passwordChange").text("phase"),"completed")
    _ = try await b.call(["method":"sync.password.unlock","passphrase":"replacement-test-passphrase"])
    _ = try await b.call(["method":"sync.run"])
    let rows=try await a.call(["method":"sync.run"])
    XCTAssertEqual(rows["keyVersion"] as? Int,1)
    let hosts=try await a.call(["method":"vault.list","collection":"hosts"]).array("items")
    XCTAssertEqual(hosts.count,1)
  }

  func testMobileNamedProfilesKeepDataWhileSwitching() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let runtime=try MobileRuntime(directory:root.appendingPathComponent("local"),testKey:Data(repeating:17,count:32))
    defer {runtime.stop()}
    var ids:[String]=[]
    for title in ["Home","Office"] {
      let result=try await runtime.call(["method":"sync.profile.add","title":title,"provider":["kind":"folder","path":root.appendingPathComponent(title).path],"name":"iOS","passphrase":"mobile-profile-password","scopes":["configuration"],"confirmed":true])
      ids=result.array("profiles").compactMap{$0["id"] as? String}
    }
    XCTAssertEqual(ids.count,2)
    _ = try await runtime.call(["method":"sync.profile.use","id":ids[0],"confirmed":true])
    _ = try await runtime.call(["method":"vault.save","collection":"hosts","item":["label":"mobile-profile","hostname":"fixture.invalid","port":22,"connectionKind":"ssh","username":"test","authentication":"password"]])
    _ = try await runtime.call(["method":"sync.profile.use","id":ids[1],"confirmed":true])
    _ = try await runtime.call(["method":"sync.run"])
    _ = try await runtime.call(["method":"sync.profile.use","id":ids[0],"confirmed":true])
    let state=try await runtime.call(["method":"sync.run"])
    XCTAssertEqual(state["activeProfile"] as? String,ids[0])
    let hosts=try await runtime.call(["method":"vault.list","collection":"hosts"]).array("items")
    XCTAssertEqual(hosts.count,1)
  }

}
