import Foundation
import TermPilotDomain
import TermPilotPersistence
import TermPilotTestSupport
import XCTest

final class PersistenceTests: XCTestCase {
    func testHostRoundTripStoresPasswordAsEncryptedVaultField() async throws {
        let databaseURL = temporaryDirectory()
            .appendingPathComponent("vault.sqlite")
        let store = try VaultStore(databaseURL: databaseURL)
        var host = Fixtures.host(authentication: .password)
        host.password = "fixture-login-value"

        try await store.saveHost(host)
        let restored = try await store.fetchHost(id: host.id)

        XCTAssertEqual(restored?.password, "fixture-login-value")

        let storedText = try persistedDatabaseText(databaseURL: databaseURL)
        XCTAssertTrue(storedText.contains("enc:v1:"))
        XCTAssertFalse(storedText.contains("fixture-login-value"))
    }

    func testHostRoundTripPreservesSFTPOptions() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        var host = Fixtures.host(authentication: .password)
        host.sftpFileProtocol = .sftp
        host.sftpFilenameEncoding = .gb18030
        host.sftpUsesSudo = true
        host.sftpFollowsTerminalCWD = true
        host.serverToolsUseRoot = true
        host.serverToolsElevationMethod = .su

        try await store.saveHost(host)
        let restored = try await store.fetchHost(id: host.id)

        XCTAssertEqual(restored?.sftpFileProtocol, .sftp)
        XCTAssertEqual(restored?.sftpFilenameEncoding, .gb18030)
        XCTAssertEqual(restored?.sftpUsesSudo, true)
        XCTAssertEqual(restored?.sftpFollowsTerminalCWD, true)
        XCTAssertEqual(restored?.serverToolsUseRoot, true)
        XCTAssertEqual(restored?.serverToolsElevationMethod, .su)
    }

    func testHostRoundTripPreservesDetectedAndManualAppearance() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        var host = Fixtures.host()
        host.distro = .debian
        host.distroMode = .manual
        host.manualDistro = .ubuntu
        host.iconMode = .custom
        host.iconID = .database
        host.iconColorMode = .manual
        host.iconColor = .violet

        try await store.saveHost(host)
        let restored = try await store.fetchHost(id: host.id)

        XCTAssertEqual(restored?.distro, .debian)
        XCTAssertEqual(restored?.distroMode, .manual)
        XCTAssertEqual(restored?.manualDistro, .ubuntu)
        XCTAssertEqual(restored?.iconMode, .custom)
        XCTAssertEqual(restored?.iconID, .database)
        XCTAssertEqual(restored?.iconColorMode, .manual)
        XCTAssertEqual(restored?.iconColor, .violet)
    }

    func testSSHCredentialRoundTripEncryptsSecrets() async throws {
        let databaseURL = temporaryDirectory()
            .appendingPathComponent("vault.sqlite")
        let store = try VaultStore(databaseURL: databaseURL)
        let credential = SSHCredential(
            label: "Production Key",
            username: "root",
            kind: .identityKey,
            privateKey: "-----BEGIN PRIVATE KEY-----\nfixture-key-material",
            publicKey: "ssh-ed25519 AAAA",
            certificate: "ssh-ed25519-cert-v01@openssh.com AAAA",
            passphrase: "fixture-passphrase-value",
            savesPassphrase: true,
            elevationPassword: "fixture-elevation-value"
        )

        try await store.saveCredential(credential)

        let restored = try await store.fetchCredentials()
        XCTAssertEqual(restored.first?.label, "Production Key")
        XCTAssertEqual(restored.first?.username, "root")
        XCTAssertEqual(restored.first?.privateKey, credential.privateKey)
        XCTAssertEqual(restored.first?.publicKey, credential.publicKey)
        XCTAssertEqual(restored.first?.certificate, credential.certificate)
        XCTAssertEqual(restored.first?.passphrase, "fixture-passphrase-value")
        XCTAssertEqual(
            restored.first?.elevationPassword,
            "fixture-elevation-value"
        )

        let storedText = try persistedDatabaseText(databaseURL: databaseURL)
        XCTAssertTrue(storedText.contains("enc:v1:"))
        XCTAssertFalse(storedText.contains("fixture-key-material"))
        XCTAssertFalse(storedText.contains("fixture-passphrase-value"))
        XCTAssertFalse(storedText.contains("fixture-elevation-value"))
    }

    func testProxyProfilesAndHostCustomProxyEncryptPasswords() async throws {
        let databaseURL = temporaryDirectory()
            .appendingPathComponent("vault.sqlite")
        let store = try VaultStore(databaseURL: databaseURL)
        let profile = SSHProxyProfile(
            label: "Office Proxy",
            configuration: SSHProxyConfiguration(
                type: .socks5,
                host: "proxy.example.invalid",
                port: 1080,
                username: "proxy-user",
                password: "fixture-saved-proxy-value"
            )
        )
        var host = Fixtures.host()
        host.proxyConfiguration = SSHProxyConfiguration(
            type: .http,
            host: "custom-proxy.example.invalid",
            port: 3128,
            username: "custom-user",
            password: "fixture-custom-proxy-value"
        )

        try await store.saveProxyProfile(profile)
        try await store.saveHost(host)

        let restoredProfile = try await store.fetchProxyProfiles().first
        let restoredHost = try await store.fetchHost(id: host.id)
        XCTAssertEqual(restoredProfile?.configuration.password, "fixture-saved-proxy-value")
        XCTAssertEqual(restoredHost?.proxyConfiguration?.password, "fixture-custom-proxy-value")

        let storedText = try persistedDatabaseText(databaseURL: databaseURL)
        XCTAssertFalse(storedText.contains("fixture-saved-proxy-value"))
        XCTAssertFalse(storedText.contains("fixture-custom-proxy-value"))
    }

    func testProxyReferencesFailClosedAndProfileDeletionUnlinksHosts() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let credential = SSHCredential(
            label: "Proxy Login",
            username: "proxy-user",
            kind: .password,
            password: "fixture-proxy-value"
        )
        let profile = SSHProxyProfile(
            label: "Office Proxy",
            configuration: SSHProxyConfiguration(
                type: .http,
                host: "proxy.example.invalid",
                port: 3128,
                credentialID: credential.id
            )
        )
        var host = Fixtures.host()
        host.proxyProfileID = profile.id

        try await store.saveCredential(credential)
        try await store.saveProxyProfile(profile)
        try await store.saveHost(host)
        try await store.deleteCredential(id: credential.id)

        let retainedProfile = try await store.fetchProxyProfiles().first
        XCTAssertEqual(
            retainedProfile?.configuration.credentialID,
            credential.id
        )

        try await store.deleteProxyProfile(id: profile.id)
        let unlinkedHost = try await store.fetchHost(id: host.id)
        XCTAssertNil(unlinkedHost?.proxyProfileID)
    }

    func testProxyProfilesAppendAndPersistManualOrder() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let first = SSHProxyProfile(
            label: "Z First",
            configuration: SSHProxyConfiguration(
                type: .socks5,
                host: "first.example.invalid",
                port: 1080
            )
        )
        var second = SSHProxyProfile(
            label: "A Second",
            configuration: SSHProxyConfiguration(
                type: .http,
                host: "second.example.invalid",
                port: 8080
            )
        )

        try await store.saveProxyProfile(first)
        try await store.saveProxyProfile(second)
        let appendedProfiles = try await store.fetchProxyProfiles()
        XCTAssertEqual(
            appendedProfiles.map(\.id),
            [first.id, second.id]
        )

        try await store.reorderProxyProfiles(ids: [second.id, first.id])
        second.label = "Updated Second"
        try await store.saveProxyProfile(second)

        let reorderedProfiles = try await store.fetchProxyProfiles()
        XCTAssertEqual(
            reorderedProfiles.map(\.id),
            [second.id, first.id]
        )
    }

    func testAssigningProxyProfileToHostsClearsOnlySelectedCustomProxies() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let profile = SSHProxyProfile(
            label: "Office Proxy",
            configuration: SSHProxyConfiguration(
                type: .socks5,
                host: "proxy.example.invalid",
                port: 1080
            )
        )
        var first = Fixtures.host(label: "First", hostname: "first.example.invalid")
        var second = Fixtures.host(label: "Second", hostname: "second.example.invalid")
        var untouched = Fixtures.host(
            label: "Untouched",
            hostname: "untouched.example.invalid"
        )
        first.proxyConfiguration = SSHProxyConfiguration(
            type: .http,
            host: "first-proxy.example.invalid",
            port: 3128,
            username: "first-user",
            password: "fixture-first-proxy-value"
        )
        second.proxyConfiguration = SSHProxyConfiguration(
            type: .command,
            command: "proxy-command %h %p"
        )
        untouched.proxyConfiguration = SSHProxyConfiguration(
            type: .http,
            host: "untouched-proxy.example.invalid",
            port: 8080
        )

        try await store.saveProxyProfile(profile)
        try await store.saveHost(first)
        try await store.saveHost(second)
        try await store.saveHost(untouched)

        try await store.assignProxyProfile(
            toHosts: [first.id, second.id],
            proxyProfileID: profile.id
        )

        let restoredFirst = try await store.fetchHost(id: first.id)
        let restoredSecond = try await store.fetchHost(id: second.id)
        let restoredUntouched = try await store.fetchHost(id: untouched.id)

        XCTAssertEqual(restoredFirst?.proxyProfileID, profile.id)
        XCTAssertNil(restoredFirst?.proxyConfiguration)
        XCTAssertEqual(restoredSecond?.proxyProfileID, profile.id)
        XCTAssertNil(restoredSecond?.proxyConfiguration)
        XCTAssertNil(restoredUntouched?.proxyProfileID)
        XCTAssertEqual(
            restoredUntouched?.proxyConfiguration,
            untouched.proxyConfiguration
        )
    }

    func testDisablingProxyClearsOnlySelectedHostProxyConfigurations() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let profile = SSHProxyProfile(
            label: "Office Proxy",
            configuration: SSHProxyConfiguration(
                type: .socks5,
                host: "proxy.example.invalid",
                port: 1080
            )
        )
        var savedProxyHost = Fixtures.host(
            label: "Saved Proxy",
            hostname: "saved.example.invalid"
        )
        var customProxyHost = Fixtures.host(
            label: "Custom Proxy",
            hostname: "custom.example.invalid"
        )
        var untouched = Fixtures.host(
            label: "Untouched",
            hostname: "untouched.example.invalid"
        )
        savedProxyHost.proxyProfileID = profile.id
        customProxyHost.proxyConfiguration = SSHProxyConfiguration(
            type: .http,
            host: "custom-proxy.example.invalid",
            port: 3128
        )
        untouched.proxyProfileID = profile.id

        try await store.saveProxyProfile(profile)
        try await store.saveHost(savedProxyHost)
        try await store.saveHost(customProxyHost)
        try await store.saveHost(untouched)

        try await store.disableProxy(
            forHosts: [savedProxyHost.id, customProxyHost.id]
        )

        let restoredSaved = try await store.fetchHost(id: savedProxyHost.id)
        let restoredCustom = try await store.fetchHost(id: customProxyHost.id)
        let restoredUntouched = try await store.fetchHost(id: untouched.id)

        XCTAssertNil(restoredSaved?.proxyProfileID)
        XCTAssertNil(restoredSaved?.proxyConfiguration)
        XCTAssertNil(restoredCustom?.proxyProfileID)
        XCTAssertNil(restoredCustom?.proxyConfiguration)
        XCTAssertEqual(restoredUntouched?.proxyProfileID, profile.id)
    }

    func testKnownHostsStoreAppendsParsesAndDeduplicatesOpenSSHLines() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("known_hosts")
        let store = try KnownHostsStore(fileURL: fileURL)
        let keyBlob = Data("ssh-ed25519-public-key-blob".utf8).base64EncodedString()
        let line = "host.example.invalid ssh-ed25519 \(keyBlob)"

        try await store.appendOpenSSHLines([line, line])
        let records = try await store.records()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.hostPattern, "host.example.invalid")
        XCTAssertEqual(records.first?.algorithm, "ssh-ed25519")
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n")
                .count,
            1
        )
    }

    func testKnownHostsStoreRemovesMultipleLineNumbersAtOnce() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("known_hosts")
        let store = try KnownHostsStore(fileURL: fileURL)
        let firstKey = Data("first-key".utf8).base64EncodedString()
        let secondKey = Data("second-key".utf8).base64EncodedString()
        let thirdKey = Data("third-key".utf8).base64EncodedString()
        try await store.appendOpenSSHLines([
            "first.example.invalid ssh-ed25519 \(firstKey)",
            "second.example.invalid ssh-ed25519 \(secondKey)",
            "third.example.invalid ssh-ed25519 \(thirdKey)",
        ])

        try await store.remove(lineNumbers: [1, 3])

        let records = try await store.records()
        XCTAssertEqual(records.map(\.hostPattern), ["second.example.invalid"])
    }

    func testDeletingGroupKeepsHostAndClearsGroupReference() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let group = HostGroup(name: "Production")
        var host = Fixtures.host()
        host.groupID = group.id

        try await store.saveGroup(group)
        try await store.saveHost(host)
        try await store.deleteGroup(id: group.id)

        let restored = try await store.fetchHost(id: host.id)
        XCTAssertNil(restored?.groupID)
    }

    func testNestedGroupRoundTripAndParentDeleteRemovesSubtree() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let parent = HostGroup(name: "Production")
        let child = HostGroup(name: "Database", parentGroupID: parent.id)
        let grandchild = HostGroup(name: "Primary", parentGroupID: child.id)
        let sibling = HostGroup(name: "Staging")
        var childHost = Fixtures.host(
            label: "Database",
            hostname: "database.example.invalid"
        )
        childHost.groupID = child.id
        var grandchildHost = Fixtures.host(
            label: "Primary",
            hostname: "primary.example.invalid"
        )
        grandchildHost.groupID = grandchild.id

        try await store.saveGroup(parent)
        try await store.saveGroup(child)
        try await store.saveGroup(grandchild)
        try await store.saveGroup(sibling)
        try await store.saveHost(childHost)
        try await store.saveHost(grandchildHost)

        let groups = try await store.fetchGroups()
        XCTAssertEqual(
            groups.first(where: { $0.id == child.id })?.parentGroupID,
            parent.id
        )

        try await store.deleteGroup(id: parent.id)

        let restoredGroups = try await store.fetchGroups()
        XCTAssertFalse(restoredGroups.contains(where: { $0.id == parent.id }))
        XCTAssertFalse(restoredGroups.contains(where: { $0.id == child.id }))
        XCTAssertFalse(restoredGroups.contains(where: { $0.id == grandchild.id }))
        XCTAssertTrue(restoredGroups.contains(where: { $0.id == sibling.id }))
        let restoredChildHost = try await store.fetchHost(id: childHost.id)
        let restoredGrandchildHost = try await store.fetchHost(
            id: grandchildHost.id
        )
        XCTAssertNil(restoredChildHost?.groupID)
        XCTAssertNil(restoredGrandchildHost?.groupID)
    }

    func testGroupCannotUseDescendantAsParent() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        var parent = HostGroup(name: "Production")
        let child = HostGroup(name: "Database", parentGroupID: parent.id)

        try await store.saveGroup(parent)
        try await store.saveGroup(child)

        parent.parentGroupID = child.id
        do {
            try await store.saveGroup(parent)
            XCTFail("Expected nested group cycle to be rejected.")
        } catch PersistenceError.invalidGroupParent {
            // Expected.
        }
    }

    func testMovingHostsToGroupOnlyUpdatesSelectedHosts() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let sourceGroup = HostGroup(name: "Source")
        let targetGroup = HostGroup(name: "Target")
        var first = Fixtures.host(label: "First", hostname: "first.example.invalid")
        var second = Fixtures.host(label: "Second", hostname: "second.example.invalid")
        var untouched = Fixtures.host(label: "Untouched", hostname: "third.example.invalid")
        first.groupID = sourceGroup.id
        second.groupID = sourceGroup.id
        untouched.groupID = sourceGroup.id

        try await store.saveGroup(sourceGroup)
        try await store.saveGroup(targetGroup)
        try await store.saveHost(first)
        try await store.saveHost(second)
        try await store.saveHost(untouched)

        try await store.moveHosts(
            ids: [first.id, second.id],
            toGroup: targetGroup.id
        )

        let restoredFirst = try await store.fetchHost(id: first.id)
        let restoredSecond = try await store.fetchHost(id: second.id)
        let restoredUntouched = try await store.fetchHost(id: untouched.id)

        XCTAssertEqual(restoredFirst?.groupID, targetGroup.id)
        XCTAssertEqual(restoredSecond?.groupID, targetGroup.id)
        XCTAssertEqual(restoredUntouched?.groupID, sourceGroup.id)
    }

    func testHostSortOrderCanMoveWithinGroupAndPersists() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let group = HostGroup(name: "Production")
        var first = Fixtures.host(label: "First", hostname: "first.example.invalid")
        var second = Fixtures.host(label: "Second", hostname: "second.example.invalid")
        var third = Fixtures.host(label: "Third", hostname: "third.example.invalid")
        first.groupID = group.id
        second.groupID = group.id
        third.groupID = group.id

        try await store.saveGroup(group)
        try await store.saveHost(first)
        try await store.saveHost(second)
        try await store.saveHost(third)
        try await store.moveHosts(
            ids: [third.id],
            toGroup: group.id,
            beforeHostID: first.id
        )

        let restored = try await store.fetchHosts()
            .filter { $0.groupID == group.id }
        XCTAssertEqual(restored.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(restored.map(\.sortOrder), [0, 1, 2])
    }

    func testMovingHostToAnotherGroupCanInsertBeforeTargetHost() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let sourceGroup = HostGroup(name: "Source")
        let targetGroup = HostGroup(name: "Target")
        var moved = Fixtures.host(label: "Moved", hostname: "moved.example.invalid")
        var first = Fixtures.host(label: "First", hostname: "first.example.invalid")
        var second = Fixtures.host(label: "Second", hostname: "second.example.invalid")
        moved.groupID = sourceGroup.id
        first.groupID = targetGroup.id
        second.groupID = targetGroup.id

        try await store.saveGroup(sourceGroup)
        try await store.saveGroup(targetGroup)
        try await store.saveHost(moved)
        try await store.saveHost(first)
        try await store.saveHost(second)
        try await store.moveHosts(
            ids: [moved.id],
            toGroup: targetGroup.id,
            beforeHostID: second.id
        )

        let restored = try await store.fetchHosts()
            .filter { $0.groupID == targetGroup.id }
        XCTAssertEqual(restored.map(\.id), [first.id, moved.id, second.id])
        XCTAssertEqual(restored.map(\.sortOrder), [0, 1, 2])
    }

    func testMovingGroupCanReorderAndChangeParent() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let parent = HostGroup(name: "Parent", sortOrder: 0)
        let sibling = HostGroup(name: "Sibling", sortOrder: 1)
        let moved = HostGroup(name: "Moved", sortOrder: 2)
        let child = HostGroup(
            name: "Child",
            parentGroupID: parent.id,
            sortOrder: 0
        )

        try await store.saveGroup(parent)
        try await store.saveGroup(sibling)
        try await store.saveGroup(moved)
        try await store.saveGroup(child)
        try await store.moveGroup(
            id: moved.id,
            toParent: nil,
            beforeGroupID: parent.id
        )
        try await store.moveGroup(
            id: moved.id,
            toParent: parent.id,
            beforeGroupID: child.id
        )

        let groups = try await store.fetchGroups()
        let rootIDs = groups
            .filter { $0.parentGroupID == nil }
            .map(\.id)
        let parentChildIDs = groups
            .filter { $0.parentGroupID == parent.id }
            .map(\.id)

        XCTAssertEqual(rootIDs, [parent.id, sibling.id])
        XCTAssertEqual(parentChildIDs, [moved.id, child.id])
        XCTAssertEqual(
            groups.first(where: { $0.id == moved.id })?.parentGroupID,
            parent.id
        )
    }

    func testMoveGroupRejectsDescendantAsParent() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let parent = HostGroup(name: "Parent")
        let child = HostGroup(name: "Child", parentGroupID: parent.id)

        try await store.saveGroup(parent)
        try await store.saveGroup(child)

        do {
            try await store.moveGroup(
                id: parent.id,
                toParent: child.id,
                beforeGroupID: nil
            )
            XCTFail("Expected moving a group under its child to be rejected.")
        } catch PersistenceError.invalidGroupParent {
            // Expected.
        }
    }

    func testLocalWorkflowRecordsRoundTrip() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let host = Fixtures.host()
        try await store.saveHost(host)

        let forward = PortForwardRule(
            hostID: host.id,
            name: "Local web",
            order: 1000,
            kind: .local,
            localPort: 8080,
            remoteHost: "127.0.0.1",
            remotePort: 80,
            autoStart: true,
            status: .active,
            error: "testing",
            lastUsedAt: Date(timeIntervalSince1970: 123)
        )
        let script = AutomationScript(
            title: "Disk",
            shell: "/bin/sh",
            body: "df -h"
        )
        let note = HostNote(
            hostID: host.id,
            title: "Runbook",
            body: "# Notes"
        )

        try await store.savePortForwardRule(forward)
        try await store.saveAutomationScript(script)
        try await store.saveHostNote(note)

        let forwards = try await store.fetchPortForwardRules()
        let scripts = try await store.fetchAutomationScripts()
        let notes = try await store.fetchHostNotes(hostID: host.id)

        XCTAssertEqual(forwards.first?.name, "Local web")
        XCTAssertEqual(forwards.first?.order, 1000)
        XCTAssertEqual(forwards.first?.autoStart, true)
        XCTAssertEqual(forwards.first?.status, .active)
        XCTAssertEqual(forwards.first?.error, "testing")
        XCTAssertEqual(forwards.first?.lastUsedAt, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(scripts.first?.body, "df -h")
        XCTAssertEqual(scripts.first?.shell, "/bin/sh")
        XCTAssertEqual(notes.first?.title, "Runbook")

        try await store.deleteAutomationScript(id: script.id)
        let remainingScripts = try await store.fetchAutomationScripts()
        XCTAssertTrue(remainingScripts.isEmpty)
    }

    func testAutomationScriptsAppendAndPersistManualOrder() async throws {
        let store = try VaultStore(
            databaseURL: temporaryDirectory().appendingPathComponent("vault.sqlite")
        )
        let first = AutomationScript(
            title: "First",
            shell: "/bin/sh",
            body: "echo first"
        )
        var second = AutomationScript(
            title: "Second",
            shell: "/bin/sh",
            body: "echo second"
        )

        try await store.saveAutomationScript(first)
        try await store.saveAutomationScript(second)
        let appendedScripts = try await store.fetchAutomationScripts()
        XCTAssertEqual(
            appendedScripts.map(\.id),
            [first.id, second.id]
        )

        try await store.reorderAutomationScripts(ids: [second.id, first.id])
        second.body = "echo updated"
        try await store.saveAutomationScript(second)

        let reorderedScripts = try await store.fetchAutomationScripts()
        XCTAssertEqual(
            reorderedScripts.map(\.id),
            [second.id, first.id]
        )
    }

    func testRemovedProtocolProfileTableIsNotCreated() throws {
        let databaseURL = temporaryDirectory()
            .appendingPathComponent("vault.sqlite")
        _ = try VaultStore(databaseURL: databaseURL)

        let storedText = try persistedDatabaseText(databaseURL: databaseURL)
        XCTAssertFalse(storedText.contains("external_protocol_profiles"))
        XCTAssertFalse(storedText.contains("last_connected_at"))
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPilotTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func persistedDatabaseText(databaseURL: URL) throws -> String {
        let directory = databaseURL.deletingLastPathComponent()
        let prefix = databaseURL.lastPathComponent
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let data = try files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .reduce(into: Data()) { partial, url in
                partial.append(try Data(contentsOf: url))
            }
        return String(decoding: data, as: UTF8.self)
    }
}
