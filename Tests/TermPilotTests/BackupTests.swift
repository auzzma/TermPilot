import Foundation
import TermPilotDomain
@testable import TermPilotPersistence
import XCTest

final class BackupTests: XCTestCase {
    func testPBKDF2SHA256MatchesPublishedVector() throws {
        let derived = try EncryptedBackupCodec.pbkdf2SHA256(
            password: "password",
            salt: Data("salt".utf8),
            iterations: 2
        )

        XCTAssertEqual(
            derived.map {
                String(format: "%02x", $0)
            }.joined(),
            "ae4d0c95af6b46d32d0adff928f06dd0"
                + "2a303f8ef3c251dfd6e2d85a95474c43"
        )
    }

    func testEncryptedBackupRoundTripRejectsWrongPassword() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = TermPilotBackupSnapshot(
            exportedAt: fixedDate,
            hosts: [],
            groups: [],
            credentials: [
                SSHCredential(
                    label: "Production",
                    username: "root",
                    kind: .password,
                    password: "fixture-encryption-value",
                    createdAt: fixedDate,
                    updatedAt: fixedDate
                ),
            ],
            proxyProfiles: [],
            portForwardRules: [],
            automationScripts: [],
            hostNotes: []
        )

        let encrypted = try EncryptedBackupCodec.encrypt(
            snapshot,
            password: "fixture-backup-value",
            iterations: 100_000
        )

        XCTAssertFalse(
            String(decoding: encrypted, as: UTF8.self)
                .contains("fixture-encryption-value")
        )
        XCTAssertEqual(
            try EncryptedBackupCodec.decrypt(
                encrypted,
                password: "fixture-backup-value"
            ),
            snapshot
        )
        XCTAssertThrowsError(
            try EncryptedBackupCodec.decrypt(
                encrypted,
                password: "fixture-wrong-backup-value"
            )
        ) {
            XCTAssertEqual(
                $0 as? EncryptedBackupError,
                .authenticationFailed
            )
        }
    }

    func testFullBackupImportDeduplicatesHostsAndRemapsReferences()
        async throws
    {
        let source = try makeStore()
        let group = HostGroup(name: "Production")
        let credential = SSHCredential(
            label: "Production Login",
            username: "root",
            kind: .password,
            password: "fixture-host-value"
        )
        let proxy = SSHProxyProfile(
            label: "Office Proxy",
            configuration: SSHProxyConfiguration(
                type: .socks5,
                host: "127.0.0.1",
                port: 1080,
                credentialID: credential.id
            )
        )
        let importedHostID = UUID()
        let importedHost = Host(
            id: importedHostID,
            label: "Imported Server",
            hostname: "192.168.001.010",
            port: 22,
            username: "root",
            authentication: .password,
            credentialID: credential.id,
            proxyProfileID: proxy.id,
            groupID: group.id
        )
        let forward = PortForwardRule(
            hostID: importedHostID,
            name: "Web",
            kind: .local,
            localPort: 8080,
            remotePort: 80
        )
        let script = AutomationScript(
            title: "Deploy",
            body: "echo deploy"
        )
        let note = HostNote(
            hostID: importedHostID,
            title: "Runbook",
            body: "# Production"
        )

        try await source.saveGroup(group)
        try await source.saveCredential(credential)
        try await source.saveProxyProfile(proxy)
        try await source.saveHost(importedHost)
        try await source.savePortForwardRule(forward)
        try await source.saveAutomationScript(script)
        try await source.saveHostNote(note)

        let snapshot = try await source.makeBackupSnapshot()
        XCTAssertEqual(snapshot.hosts.count, 1)
        XCTAssertEqual(snapshot.groups, [group])
        XCTAssertEqual(snapshot.credentials.count, 1)
        XCTAssertEqual(snapshot.proxyProfiles.count, 1)
        XCTAssertEqual(snapshot.portForwardRules.count, 1)
        XCTAssertEqual(snapshot.automationScripts.count, 1)
        XCTAssertEqual(snapshot.hostNotes.count, 1)

        let destination = try makeStore()
        let existingHostID = UUID()
        try await destination.saveHost(
            Host(
                id: existingHostID,
                label: "Existing Server",
                hostname: "192.168.1.10",
                username: "admin"
            )
        )

        let summary = try await destination.importBackupSnapshot(
            snapshot
        )

        XCTAssertEqual(summary.hosts, 1)
        XCTAssertEqual(summary.deduplicatedHosts, 1)
        let hosts = try await destination.fetchHosts()
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].id, existingHostID)
        XCTAssertEqual(hosts[0].label, "Imported Server")
        XCTAssertEqual(hosts[0].credentialID, credential.id)
        XCTAssertEqual(hosts[0].proxyProfileID, proxy.id)
        XCTAssertEqual(hosts[0].groupID, group.id)

        let credentials = try await destination.fetchCredentials()
        let proxies = try await destination.fetchProxyProfiles()
        let forwards = try await destination.fetchPortForwardRules()
        let scripts = try await destination.fetchAutomationScripts()
        let notes = try await destination.fetchHostNotes()
        XCTAssertEqual(credentials.first?.password, "fixture-host-value")
        XCTAssertEqual(proxies.first?.id, proxy.id)
        XCTAssertEqual(forwards.first?.hostID, existingHostID)
        XCTAssertEqual(scripts.first?.id, script.id)
        XCTAssertEqual(notes.first?.hostID, existingHostID)
    }

    func testBackupImportRollsBackAllDataOnValidationFailure()
        async throws
    {
        let store = try makeStore()
        let snapshot = TermPilotBackupSnapshot(
            hosts: [
                Host(
                    label: "",
                    hostname: "192.0.2.10",
                    username: "root"
                ),
            ],
            groups: [],
            credentials: [
                SSHCredential(
                    label: "Should Roll Back",
                    username: "root",
                    kind: .password,
                    password: "fixture-login-value"
                ),
            ],
            proxyProfiles: [],
            portForwardRules: [],
            automationScripts: [],
            hostNotes: []
        )

        do {
            _ = try await store.importBackupSnapshot(snapshot)
            XCTFail("Expected import validation to fail")
        } catch {
            XCTAssertEqual(
                error as? HostValidationError,
                .missingLabel
            )
        }
        let hosts = try await store.fetchHosts()
        let credentials = try await store.fetchCredentials()
        XCTAssertTrue(hosts.isEmpty)
        XCTAssertTrue(credentials.isEmpty)
    }

    private func makeStore() throws -> VaultStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try VaultStore(
            databaseURL: directory.appendingPathComponent("vault.sqlite")
        )
    }
}
