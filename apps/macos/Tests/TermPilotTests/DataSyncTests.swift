import XCTest
import TermPilotCore
import TermPilotDomain
import TermPilotPersistence

final class DataSyncTests: XCTestCase {
    func testQRCodeFramesAndInvalidInviteThroughSwiftBridge() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("invite-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let result=try SharedCore.call(["method":"sync.qr.decode","width":640,"height":480,"pixels":Data(repeating:255,count:640*480).base64EncodedString()])
        XCTAssertTrue(result["code"] is NSNull)
        XCTAssertThrowsError(try SharedCore.call(["method":"sync.invite.preview","directory":root.path,"passphrase":"bridge-test-key-123","code":"TP-SYNC:2:unsupported"]))
        let status=try SharedCore.call(["method":"sync.status","directory":root.path])
        XCTAssertEqual((status["profiles"] as? [Any])?.count,0)
    }

    func testNativeGRDBWritesJoinRustReplicaAndRestoreKeepsLocalSecret() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-sync-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let local=root.appendingPathComponent("native"), remote=root.appendingPathComponent("rust")
        try FileManager.default.createDirectory(at:local,withIntermediateDirectories:true)
        let native=try VaultStore(databaseURL:local.appendingPathComponent("vault.sqlite"))
        let library=UUID().uuidString
        func call(_ directory:URL,_ command:[String:Any]) throws -> [String:Any] {
            var request=command;request["directory"]=directory.path
            return try SharedCore.call(request)
        }
        for directory in [local,remote] {
            _ = try call(directory,["method":"sync.configure","provider":["kind":"folder","path":root.appendingPathComponent("cloud").path],"library":library,"name":directory.lastPathComponent,"passphrase":"sync-test-passphrase-only","scopes":["configuration"],"confirmed":true])
        }
        let host=TermPilotDomain.Host(label:"Native 中文",hostname:"sync-fixture.invalid",username:"fixture",authentication:.password,password:"local-only-fixture")
        try await native.saveHost(host)
        _ = try call(local,["method":"sync.run"])
        _ = try call(remote,["method":"sync.run"])
        let rows=try call(remote,["method":"vault.list","collection":"hosts"])["items"] as? [[String:Any]] ?? []
        XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows.first?["label"] as? String,"Native 中文")
        XCTAssertNil(rows.first?["password"] as? String)
        _ = try call(local,["method":"vault.delete","collection":"hosts","id":host.id.uuidString])
        let state=try call(local,["method":"sync.run"])
        let item=try XCTUnwrap((state["recycle"] as? [[String:Any]])?.first)
        _ = try call(local,["method":"sync.restore","ids":[item["id"]!],"actionId":UUID().uuidString,"confirmed":true])
        let recovered=try await native.fetchHosts()
        XCTAssertEqual(recovered.count,1)
        XCTAssertNotEqual(recovered.first?.id,host.id)
        XCTAssertEqual(recovered.first?.password,"local-only-fixture")
    }
    func testPasswordChangeThroughSwiftBridgeKeepsOfflineChanges() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-rekey-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let a=root.appendingPathComponent("A"), b=root.appendingPathComponent("B")
        let library=UUID().uuidString
        func call(_ directory:URL,_ command:[String:Any]) throws -> [String:Any] {
            var request=command;request["directory"]=directory.path;return try SharedCore.call(request)
        }
        for directory in [a,b] {
            _ = try call(directory,["method":"sync.configure","provider":["kind":"folder","path":root.appendingPathComponent("cloud").path],"library":library,"passphrase":"original-test-passphrase","confirmed":true])
        }
        _ = try call(a,["method":"sync.run"])
        _ = try call(b,["method":"sync.run"])
        _ = try call(b,["method":"vault.save","collection":"hosts","item":["label":"offline", "hostname":"fixture.invalid", "port":22,"username":"test","authentication":"password","connectionKind":"ssh"]])
        _ = try call(a,["method":"sync.password.begin","oldPassphrase":"original-test-passphrase","newPassphrase":"replacement-test-passphrase","confirmPassphrase":"replacement-test-passphrase","confirmed":true,"clientsUpdated":true])
        let progress=try call(a,["method":"sync.password.resume"])["passwordChange"] as? [String:Any]
        XCTAssertEqual(progress?["phase"] as? String,"completed")
        XCTAssertThrowsError(try call(b,["method":"sync.run"]))
        _ = try call(b,["method":"sync.password.unlock","passphrase":"replacement-test-passphrase"])
        _ = try call(b,["method":"sync.run"])
        _ = try call(a,["method":"sync.run"])
        XCTAssertEqual((try call(a,["method":"vault.list","collection":"hosts"])["items"] as? [[String:Any]])?.count,1)
    }

    func testNamedCloudConfigurationsThroughNativeBridge() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-profiles-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let local=root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at:local,withIntermediateDirectories:true)
        let native=try VaultStore(databaseURL:local.appendingPathComponent("vault.sqlite"))
        func call(_ command:[String:Any]) throws -> [String:Any] {
            var request=command;request["directory"]=local.path;return try SharedCore.call(request)
        }
        var ids:[String]=[]
        for title in ["Home","Office"] {
            let result=try call(["method":"sync.profile.add","title":title,"provider":["kind":"folder","path":root.appendingPathComponent(title).path],"name":"Mac","passphrase":"native-profile-password","scopes":["configuration"],"confirmed":true])
            ids=(result["profiles"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String}
        }
        XCTAssertEqual(ids.count,2)
        _ = try call(["method":"sync.profile.use","id":ids[0],"confirmed":true])
        let host=TermPilotDomain.Host(label:"Profile 中文",hostname:"fixture.invalid",username:"fixture",authentication:.password,password:"local-only")
        try await native.saveHost(host)
        _ = try call(["method":"sync.profile.use","id":ids[1],"confirmed":true])
        _ = try call(["method":"vault.delete","collection":"hosts","id":host.id.uuidString])
        _ = try call(["method":"sync.profile.use","id":ids[0],"confirmed":true])
        let state=try call(["method":"sync.run"])
        XCTAssertEqual((state["recycle"] as? [[String:Any]])?.count,1)
        let hosts=try await native.fetchHosts()
        XCTAssertTrue(hosts.isEmpty)
    }

}
