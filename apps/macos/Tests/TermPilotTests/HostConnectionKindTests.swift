import Foundation
import GRDB
import TermPilotCore
import TermPilotDomain
@testable import TermPilotPersistence
@testable import TermPilotApp
import XCTest

final class HostConnectionKindTests: XCTestCase {
    @MainActor
    func testNewAndDuplicatedHostsRemainEditableWithSyncEnabled() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        _ = try SharedCore.call(["method": "sync.configure", "directory": directory.path,
            "provider": ["kind": "folder", "path": directory.appendingPathComponent("cloud").path],
            "passphrase": "host-editor-test-key-only", "confirmed": true])
        let state = AppState(vaultStore: store)
        for kind in [HostConnectionKind.ssh, .screenSharing, .rdp] {
            let host = Host(label: "  New \(kind.rawValue)  ", hostname: "fixture.invalid",
                            connectionKind: kind, username: "fixture")
            let profile: ScreenSharingProfile? = kind == .ssh ? nil : ScreenSharingProfile(
                hostID: host.id, port: kind == .rdp ? 3389 : 5900, username: "fixture",
                password: "profile-fixture", mode: kind == .rdp ? .rdp : .highPerformance)
            let created = await state.saveHost(host, password: nil, screenSharingProfile: profile)
            XCTAssertTrue(created, "Blank new hosts must save with sync enabled")
            let savedSource = try await store.fetchHost(id: host.id)
            let duplicated = await state.duplicateHost(try XCTUnwrap(savedSource))
            var copy = try XCTUnwrap(duplicated)
            let stored = try await store.fetchHost(id: copy.id)
            XCTAssertEqual(copy, stored, "The editor must receive the persisted record and revision, not the pre-save draft")
            let copiedProfile = try await store.screenSharingProfile(hostID: copy.id)
            copy.label = "Edited copy \(kind.rawValue)"
            let saved = await state.saveHost(copy, password: nil, screenSharingProfile: copiedProfile)
            XCTAssertTrue(saved, state.presentedError ?? "Copy must remain editable")
            let edited = try await store.fetchHost(id: copy.id)
            XCTAssertEqual(edited?.label, copy.label)
            let original = try await store.fetchHost(id: host.id)
            XCTAssertEqual(original?.label, "New \(kind.rawValue)")
        }
    }

    @MainActor
    func testRealConcurrentEditIsStillRejectedWithoutOverwritingHostOrProfile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        _ = try SharedCore.call(["method": "sync.configure", "directory": directory.path,
            "provider": ["kind": "folder", "path": directory.appendingPathComponent("cloud").path],
            "passphrase": "host-editor-test-key-only", "confirmed": true])
        let host = Host(label: "Original", hostname: "fixture.invalid", connectionKind: .screenSharing, username: "fixture")
        let profile = ScreenSharingProfile(hostID: host.id, username: "fixture", password: "original-fixture")
        try await store.saveHost(host, screenSharingProfile: profile)
        let loaded = try await store.fetchHost(id: host.id)
        var stale = try XCTUnwrap(loaded)
        var other = stale
        other.label = "Changed elsewhere"
        try await Task.sleep(for: .milliseconds(20))
        try await store.saveHost(other)
        stale.label = "Stale draft"
        var changedProfile = profile
        changedProfile.password = "must-not-overwrite"
        let state = AppState(vaultStore: store)
        let saved = await state.saveHost(stale, password: nil, screenSharingProfile: changedProfile)
        XCTAssertFalse(saved)
        XCTAssertNotNil(state.presentedError)
        let retained = try await store.fetchHost(id: host.id)
        let retainedProfile = try await store.screenSharingProfile(hostID: host.id)
        XCTAssertEqual(retained?.label, other.label)
        XCTAssertEqual(retainedProfile, profile)
    }

    func testOldHostJSONDefaultsToSSHAndRemoteHostRoundTrips() throws {
        var host = Host(label: "Mac", hostname: "mac.local", username: "ssh-user")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        legacy.removeValue(forKey: "connectionKind")
        let decoded = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded, host)
        host.connectionKind = .screenSharing
        XCTAssertEqual(try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host)), host)
    }

    func testMigrationPreservesExistingHostAndScreenSharingCredential() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vault.sqlite")
        let original = try VaultStore(databaseURL: url)
        let host = Host(label: "Existing", hostname: "mac.local", username: "ssh-user")
        let profile = ScreenSharingProfile(hostID: host.id, username: "mac-user", password: "fixture-screen-password")
        try await original.saveHost(host, screenSharingProfile: profile)
        // Recreate the previous schema with real encrypted rows, then reopen it.
        let oldDatabase = try DatabaseQueue(path: url.path)
        try await oldDatabase.write { db in
            try db.execute(sql: "ALTER TABLE hosts DROP COLUMN connection_kind")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v17-host-connection-kind'")
        }
        let upgraded = try VaultStore(databaseURL: url)
        let hosts = try await upgraded.fetchHosts()
        let restored = try await upgraded.screenSharingProfile(hostID: host.id)
        XCTAssertEqual(hosts.map(\.id), [host.id])
        XCTAssertEqual(hosts.first?.connectionKind, .ssh)
        XCTAssertEqual(restored, profile)
    }

    @MainActor
    func testEditingRemoteHostPreservesSSHSettingsAndBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let state = AppState(vaultStore: store)
        var host = Host(label: "Mac", hostname: "mac.local", port: 2222,
                        username: "ssh-user", authentication: .password, password: "fixture-ssh-password")
        try await store.saveHost(host)
        host.connectionKind = .screenSharing
        let profile = ScreenSharingProfile(hostID: host.id, port: 5901, username: "mac-user",
                                           password: "fixture-screen-password", audio: false)
        let saved = await state.saveHost(host, password: nil, screenSharingProfile: profile)
        XCTAssertTrue(saved)
        let restored = try await store.fetchHost(id: host.id)
        XCTAssertEqual(restored?.connectionKind, .screenSharing)
        XCTAssertEqual(restored?.username, "ssh-user")
        XCTAssertEqual(restored?.port, 2222)
        XCTAssertEqual(restored?.password, "fixture-ssh-password")

        let snapshot = try await store.makeBackupSnapshot()
        let encoded = try EncryptedBackupCodec.encrypt(snapshot, password: "fixture-backup", iterations: 100_000)
        let decoded = try EncryptedBackupCodec.decrypt(encoded, password: "fixture-backup")
        let destination = try VaultStore(databaseURL: directory.appendingPathComponent("import.sqlite"))
        _ = try await destination.importBackupSnapshot(decoded)
        let imported = try await destination.fetchHost(id: host.id)
        let importedProfile = try await destination.screenSharingProfile(hostID: host.id)
        XCTAssertEqual(imported?.connectionKind, .screenSharing)
        XCTAssertEqual(importedProfile, profile)

        host.connectionKind = .ssh
        let switched = await state.saveHost(host, password: nil)
        XCTAssertTrue(switched)
        let retainedProfile = try await store.screenSharingProfile(hostID: host.id)
        XCTAssertEqual(retainedProfile, profile)
    }

    func testInvalidRemoteProfileCannotPartiallySaveHost() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let host = Host(label: "Mac", hostname: "mac.local", connectionKind: .screenSharing, username: "")
        for profile in [
            ScreenSharingProfile(hostID: host.id, port: 0, username: "mac-user"),
            ScreenSharingProfile(hostID: UUID(), username: "mac-user"),
            ScreenSharingProfile(hostID: host.id, username: " ")
        ] {
            do {
                try await store.saveHost(host, screenSharingProfile: profile)
                XCTFail("Invalid profile must be rejected")
            } catch { XCTAssertTrue(error is ScreenSharingConfigurationError) }
        }
        let hosts = try await store.fetchHosts()
        XCTAssertTrue(hosts.isEmpty)
    }

    @MainActor
    func testDefaultConnectionAndSplitUseRemoteProfileWithoutStartingSSH() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let state = AppState(vaultStore: store)
        // Broken/unused SSH settings must not prevent a remote desktop connection.
        let host = Host(label: "Mac", hostname: "fixture.invalid", connectionKind: .screenSharing,
                        port: 2222, username: "", authentication: .identityFile, credentialID: UUID())
        let profile = ScreenSharingProfile(hostID: host.id, port: 5901, username: "mac-user", audio: false)
        try await store.saveHost(host, screenSharingProfile: profile)
        await state.connect(host: host)
        let session = try XCTUnwrap(state.sessions.values.first)
        XCTAssertEqual(session.kind, .screenSharing)
        XCTAssertEqual(session.port, 5901)
        XCTAssertEqual(session.username, "mac-user")
        XCTAssertEqual(session.screenSharingAudio, false)
        XCTAssertEqual(state.screenSharingRuntimes[session.id]?.lifecycle, .disconnected)
        XCTAssertTrue(state.runtimes.isEmpty)
        XCTAssertNil(state.presentedError)
        await state.connect(host: host, splitAxis: .vertical)
        XCTAssertEqual(state.activeWorkspace?.root.paneCount, 2)
        XCTAssertEqual(state.screenSharingRuntimes.count, 2)
        await state.closeWorkspace(try XCTUnwrap(state.activeWorkspaceID))
    }

    @MainActor
    func testDuplicatingRemoteHostCopiesIndependentProfileAndForgettingPassword() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let state = AppState(vaultStore: store)
        let host = Host(label: "Mac", hostname: "mac.local", connectionKind: .screenSharing, username: "ssh-user")
        var profile = ScreenSharingProfile(hostID: host.id, username: "mac-user", password: "fixture-screen-password")
        try await store.saveHost(host, screenSharingProfile: profile)
        let duplicated = await state.duplicateHost(host)
        let copy = try XCTUnwrap(duplicated)
        let copiedProfile = try await store.screenSharingProfile(hostID: copy.id)
        XCTAssertEqual(copy.connectionKind, .screenSharing)
        XCTAssertNotEqual(copy.id, host.id)
        XCTAssertEqual(copiedProfile?.hostID, copy.id)
        XCTAssertEqual(copiedProfile?.password, profile.password)
        profile.password = nil
        let saved = await state.saveHost(host, password: nil, screenSharingProfile: profile)
        XCTAssertTrue(saved)
        let forgotten = try await store.screenSharingProfile(hostID: host.id)
        XCTAssertNil(forgotten?.password)
        let retainedCopy = try await store.screenSharingProfile(hostID: copy.id)
        XCTAssertNotNil(retainedCopy?.password)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("host-kind-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
