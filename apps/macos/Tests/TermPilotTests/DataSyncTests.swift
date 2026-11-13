import XCTest
import TermPilotCore
import TermPilotDomain
import TermPilotPersistence

final class DataSyncTests: XCTestCase {
    func testCompleteVersionHistoryCountThroughNativeBridge() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-full-sync-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let directory=root.appendingPathComponent("A")
        func call(_ command:[String:Any]) throws -> [String:Any] {
            var command=command;command["directory"]=directory.path;return try SharedCore.call(command)
        }
        _ = try call(["method":"sync.configure","provider":["kind":"folder","path":root.appendingPathComponent("cloud").path],"passphrase":"whole-version-fixture-key","confirmed":true])
        _ = try call(["method":"sync.configure","historyVersionCount":1,"confirmed":true])
        XCTAssertThrowsError(try call(["method":"sync.configure","historyVersionCount":0,"confirmed":true]))
        for port in [22,2222,2223] {
            _ = try call(["method":"sync.preferences","values":["theme":port == 22 ? "dark" : "light"]])
            _ = try call(["method":"sync.snapshot"])
            _ = try call(["method":"sync.run"])
        }
        let status=try call(["method":"sync.status"])
        XCTAssertEqual(status["fullVersionSync"] as? Bool,true)
        XCTAssertEqual(status["historyVersionCount"] as? Int,1)
        let snapshots=try XCTUnwrap(status["snapshots"] as? [[String:Any]])
        XCTAssertEqual(snapshots.count,2)
        XCTAssertTrue(snapshots.allSatisfy{$0["fullVersion"] as? Bool == true})
        let cloud=root.appendingPathComponent("cloud")
        let names=try FileManager.default.contentsOfDirectory(atPath:cloud.path)
        XCTAssertTrue(names.contains("current"));XCTAssertTrue(names.contains("history"))
        XCTAssertFalse(names.contains(where:{$0.hasSuffix("-current") || $0.hasSuffix("-history")}))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:cloud.appendingPathComponent("current").path).count,1)
    }
    func testConflictDetailsAndSelectedResolutionThroughNativeBridge() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-conflicts-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let a=root.appendingPathComponent("A"), b=root.appendingPathComponent("B"), library=UUID().uuidString
        func call(_ directory:URL,_ command:[String:Any]) throws -> [String:Any] {
            var command=command;command["directory"]=directory.path;return try SharedCore.call(command)
        }
        for directory in [a,b] {
            _ = try call(directory,["method":"sync.configure","name":directory.lastPathComponent,"library":library,"provider":["kind":"folder","path":root.appendingPathComponent("cloud").path],"passphrase":"conflict-fixture-passphrase","confirmed":true])
        }
        _ = try call(a,["method":"vault.save","collection":"hosts","item":["label":"Development host","hostname":"original.invalid","port":22,"username":"fixture","authentication":"password","connectionKind":"ssh"]])
        _ = try call(a,["method":"sync.run"]);_ = try call(b,["method":"sync.run"])
        for (directory,address) in [(a,"first.invalid"),(b,"second.invalid")] {
            var host=try XCTUnwrap((try call(directory,["method":"vault.list","collection":"hosts"])["items"] as? [[String:Any]])?.first)
            host["hostname"]=address;_ = try call(directory,["method":"vault.save","collection":"hosts","item":host])
        }
        _ = try call(a,["method":"sync.run"]);_ = try call(b,["method":"sync.run"])
        let status=try call(a,["method":"sync.run"])
        let conflict=try XCTUnwrap((status["conflicts"] as? [[String:Any]])?.first)
        XCTAssertEqual(conflict["title"] as? String,"主机：Development host")
        let field=try XCTUnwrap((conflict["details"] as? [[String:Any]])?.first(where:{$0["key"] as? String == "hostname"}))
        XCTAssertEqual(field["label"] as? String,"主机地址 / IP")
        let candidates=try XCTUnwrap(field["candidates"] as? [[String:Any]])
        XCTAssertEqual(Set(candidates.compactMap{$0["display"] as? String}),Set(["first.invalid","second.invalid"]))
        let selected=try XCTUnwrap(candidates.first(where:{$0["display"] as? String == "first.invalid"}))
        let resolved=try call(a,["method":"sync.resolve","scope":"configuration","id":conflict["id"]!,"revision":conflict["revision"]!,"choices":["hostname":selected["dot"]!],"confirmed":true])
        XCTAssertTrue((resolved["conflicts"] as? [[String:Any]] ?? []).isEmpty)
        XCTAssertNotNil(status["maintenance"])
        _ = try call(a,["method":"sync.run"]);_ = try call(b,["method":"sync.run"])
        XCTAssertEqual((try call(b,["method":"vault.list","collection":"hosts"])["items"] as? [[String:Any]])?.first?["hostname"] as? String,"first.invalid")
    }


    func testLeaseTimeoutPersistsAndRejectsInvalidMinutesThroughSwiftBridge() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-lease-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        func call(_ command:[String:Any]) throws -> [String:Any] {
            var request=command;request["directory"]=root.appendingPathComponent("local").path
            return try SharedCore.call(request)
        }
        let initial=try call(["method":"sync.configure","provider":["kind":"folder","path":root.appendingPathComponent("cloud").path],"passphrase":"lease-test-passphrase","confirmed":true])
        XCTAssertEqual(initial["lockTimeoutMinutes"] as? Int,60)
        _ = try call(["method":"sync.configure","lockTimeoutMinutes":17,"confirmed":true])
        XCTAssertThrowsError(try call(["method":"sync.configure","lockTimeoutMinutes":0,"confirmed":true]))
        XCTAssertEqual(try call(["method":"sync.status"])["lockTimeoutMinutes"] as? Int,17)
        let result=try call(["method":"sync.run"])
        XCTAssertEqual(result["lockTimeoutMinutes"] as? Int,17)
    }

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
