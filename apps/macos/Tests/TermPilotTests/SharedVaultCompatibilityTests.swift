import Foundation
import XCTest
import TermPilotCore
import TermPilotDomain
import TermPilotPersistence
import TermPilotTestSupport

final class SharedVaultCompatibilityTests: XCTestCase {
    func testSwiftRustDatabaseAndEncryptedBackupRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-compat-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        var host = Fixtures.host(authentication: .password)
        host.password = "synthetic-中文-password"
        try await store.saveHost(host)
        let credential = SSHCredential(label: "Fixture credential", username: "fixture", kind: .password, password: "synthetic-credential", elevationMethod: .su)
        try await store.saveCredential(credential)
        func call(_ method: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
            var fields = arguments; fields["method"] = "vault." + method; fields["directory"] = directory.path
            return try SharedCore.call(fields)
        }
        let response = try call("get", ["collection": "hosts", "id": host.id.uuidString])
        var item = try XCTUnwrap(response["item"] as? [String: Any])
        XCTAssertEqual(item["password"] as? String, host.password)
        item["label"] = "Edited through Rust"
        item["password"] = "rust-secret-中文"
        _ = try call("save", ["collection": "hosts", "item": item])
        let restored = try await store.fetchHost(id: host.id)
        XCTAssertEqual(restored?.label, "Edited through Rust")
        XCTAssertEqual(restored?.password, "rust-secret-中文")
        let credentialResponse = try call("get", ["collection": "credentials", "id": credential.id.uuidString])
        var savedCredential = try XCTUnwrap(credentialResponse["item"] as? [String: Any])
        XCTAssertEqual(savedCredential["elevationMethod"] as? String, "su")
        savedCredential["elevationMethod"] = "sudo"
        _ = try call("save", ["collection": "credentials", "item": savedCredential])
        let swiftCredentials = try await store.fetchCredentials()
        XCTAssertEqual(swiftCredentials.first?.elevationMethod, .sudo)
        let backup = directory.appendingPathComponent("rust.tpbackup")
        _ = try call("export", ["path": backup.path, "password": "fixture-backup"])
        let decoded = try EncryptedBackupCodec.decrypt(Data(contentsOf: backup), password: "fixture-backup")
        XCTAssertEqual(decoded.hosts.first?.password, "rust-secret-中文")
        XCTAssertEqual(decoded.credentials.first?.password, "synthetic-credential")
        XCTAssertEqual(decoded.credentials.first?.elevationMethod, .sudo)
        let swiftBackup = try EncryptedBackupCodec.encrypt(try await store.makeBackupSnapshot(), password: "fixture-backup")
        try swiftBackup.write(to: backup)
        _ = try call("import", ["path": backup.path, "password": "fixture-backup"])
        let importedCredentials = try await store.fetchCredentials()
        XCTAssertEqual(importedCredentials.first?.elevationMethod, .sudo)
        let all = try await store.fetchHosts()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, host.id)
    }
}
