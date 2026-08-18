import AppKit
@testable import TermPilotApp
import TermPilotDomain
import TermPilotRemote
import TermPilotTestSupport
import XCTest

final class WindowStateTests: XCTestCase {
    @MainActor
    func testHostEditorPortFormatNeverUsesGroupingSeparators() {
        for localeID in ["en_US", "zh_CN", "de_DE"] {
            let formatted = HostEditorView.portFormat
                .locale(Locale(identifier: localeID))
                .format(11_111)
            XCTAssertEqual(formatted, "11111", localeID)
        }
    }

    func testTabInfoPopoverDismissesBeforeContextMenuClick() throws {
        let rightClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        let controlClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        let leftClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        XCTAssertTrue(
            TabInfoPopoverEventPolicy.dismissesPopover(for: rightClick)
        )
        XCTAssertTrue(
            TabInfoPopoverEventPolicy.dismissesPopover(for: controlClick)
        )
        XCTAssertFalse(
            TabInfoPopoverEventPolicy.dismissesPopover(for: leftClick)
        )
    }

    func testServerToolsTransportErrorRecoveryClassification() {
        XCTAssertTrue(
            AppState.isRecoverableServerToolsTransportError(
                POSIXError(.EBADF)
            )
        )
        XCTAssertTrue(
            AppState.isRecoverableServerToolsTransportError(
                SSH2SFTPBridgeError.closed
            )
        )
        XCTAssertTrue(
            AppState.isRecoverableServerToolsTransportError(
                SSH2SFTPBridgeError.remote(
                    "Shared SSH broker connection closed."
                )
            )
        )
        XCTAssertFalse(
            AppState.isRecoverableServerToolsTransportError(
                SSH2SFTPBridgeError.remote("Permission denied.")
            )
        )
        XCTAssertFalse(
            AppState.isRecoverableServerToolsTransportError(
                CancellationError()
            )
        )
    }

    func testHostGroupDragFallbackRequiresGroupPrefix() {
        let groupID = UUID()
        let hostID = UUID()

        XCTAssertEqual(
            HostGroupDragPayload.fallbackGroupID(
                from: Data("group:\(groupID.uuidString)".utf8)
            ),
            groupID
        )
        XCTAssertNil(
            HostGroupDragPayload.fallbackGroupID(
                from: Data(hostID.uuidString.utf8)
            )
        )
        XCTAssertEqual(
            HostDragPayload.hostID(from: Data(hostID.uuidString.utf8)),
            hostID
        )
    }

    func testTopTabQuickSwitcherSearchMatchesSavedHostFieldsAndGroupPath() {
        let production = HostGroup(name: "Production")
        let database = HostGroup(
            name: "Database",
            parentGroupID: production.id
        )
        var primary = Fixtures.host(
            label: "Primary DB",
            hostname: "host.example.invalid"
        )
        primary.groupID = database.id
        let bastion = Fixtures.host(
            label: "Bastion",
            hostname: "gateway.example.invalid"
        )
        let hosts = [primary, bastion]
        let groups = [production, database]

        XCTAssertEqual(
            TopTabQuickSwitcherSearch.hosts(
                matching: "primary",
                hosts: hosts,
                groups: groups
            ).map(\.id),
            [primary.id]
        )
        XCTAssertEqual(
            TopTabQuickSwitcherSearch.hosts(
                matching: "host.example.invalid",
                hosts: hosts,
                groups: groups
            ).map(\.id),
            [primary.id]
        )
        XCTAssertEqual(
            TopTabQuickSwitcherSearch.hosts(
                matching: "pilot@gateway",
                hosts: hosts,
                groups: groups
            ).map(\.id),
            [bastion.id]
        )
        XCTAssertEqual(
            TopTabQuickSwitcherSearch.hosts(
                matching: "production / database",
                hosts: hosts,
                groups: groups
            ).map(\.id),
            [primary.id]
        )
        XCTAssertTrue(
            TopTabQuickSwitcherSearch.hosts(
                matching: "missing",
                hosts: hosts,
                groups: groups
            ).isEmpty
        )
    }

    func testHostGroupHierarchyCollectsHostsFromAllDescendantGroups() {
        let root = HostGroup(name: "Production")
        let child = HostGroup(name: "Database", parentGroupID: root.id)
        let grandchild = HostGroup(name: "Primary", parentGroupID: child.id)
        let sibling = HostGroup(name: "Staging")
        var rootHost = Fixtures.host(label: "Root", hostname: "root.example.invalid")
        var childHost = Fixtures.host(label: "Child", hostname: "child.example.invalid")
        var grandchildHost = Fixtures.host(
            label: "Grandchild",
            hostname: "grandchild.example.invalid"
        )
        var siblingHost = Fixtures.host(
            label: "Sibling",
            hostname: "sibling.example.invalid"
        )
        let ungroupedHost = Fixtures.host(
            label: "Ungrouped",
            hostname: "ungrouped.example.invalid"
        )
        rootHost.groupID = root.id
        childHost.groupID = child.id
        grandchildHost.groupID = grandchild.id
        siblingHost.groupID = sibling.id
        let groups = [root, child, grandchild, sibling]
        let hosts = [
            rootHost,
            childHost,
            grandchildHost,
            siblingHost,
            ungroupedHost,
        ]

        XCTAssertEqual(
            HostGroupHierarchy.hostIDs(
                includingDescendantsOf: root.id,
                groups: groups,
                hosts: hosts
            ),
            [rootHost.id, childHost.id, grandchildHost.id]
        )
        XCTAssertEqual(
            HostGroupHierarchy.hostIDs(
                includingDescendantsOf: child.id,
                groups: groups,
                hosts: hosts
            ),
            [childHost.id, grandchildHost.id]
        )
        XCTAssertEqual(
            HostGroupHierarchy.groupIDs(
                includingDescendantsOf: root.id,
                groups: groups
            ),
            [root.id, child.id, grandchild.id]
        )
        let groupedHostIDs = Set([
            rootHost.id,
            childHost.id,
            grandchildHost.id,
        ])
        XCTAssertEqual(
            HostGroupHierarchy.selectionState(
                hostIDs: groupedHostIDs,
                selectedHostIDs: []
            ),
            .none
        )
        XCTAssertEqual(
            HostGroupHierarchy.selectionState(
                hostIDs: groupedHostIDs,
                selectedHostIDs: [rootHost.id]
            ),
            .partial
        )
        XCTAssertEqual(
            HostGroupHierarchy.selectionState(
                hostIDs: groupedHostIDs,
                selectedHostIDs: groupedHostIDs
            ),
            .all
        )
    }

    func testQuickConnectHostIdentityIsStableAndHostCaseInsensitive() {
        let first = QuickConnectHostIdentity.id(
            hostname: "HOST.EXAMPLE.INVALID",
            port: 22,
            username: "root"
        )
        let second = QuickConnectHostIdentity.id(
            hostname: "host.example.INVALID",
            port: 22,
            username: "root"
        )
        let differentUsername = QuickConnectHostIdentity.id(
            hostname: "host.example.invalid",
            port: 22,
            username: "Root"
        )
        let differentPort = QuickConnectHostIdentity.id(
            hostname: "host.example.invalid",
            port: 2222,
            username: "root"
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, differentUsername)
        XCTAssertNotEqual(first, differentPort)
    }

    func testQuickConnectHostCarriesServerToolsConfiguration() {
        let credentialID = UUID()
        let host = AppState.makeQuickConnectHost(
            hostname: "host.example.invalid",
            port: 2200,
            username: "pilot",
            authentication: .identityFile,
            identityFile: nil,
            identityKey: nil,
            publicKey: nil,
            certificate: nil,
            passphrase: nil,
            password: nil,
            elevationPassword: "fixture-elevation-value",
            credentialID: credentialID,
            serverToolsUseRoot: true,
            serverToolsElevationMethod: .su
        )
        let descriptor = SessionDescriptor.ssh(host: host)

        XCTAssertEqual(host.credentialID, credentialID)
        XCTAssertTrue(host.serverToolsUseRoot)
        XCTAssertEqual(host.serverToolsElevationMethod, .su)
        XCTAssertEqual(host.elevationPassword, "fixture-elevation-value")
        XCTAssertEqual(descriptor.serverToolsUseRoot, true)
        XCTAssertEqual(
            descriptor.serverToolsElevationMethod,
            .su
        )
    }

    func testQuickConnectPasswordCredentialUsesEditedFields() {
        let credential = SSHCredential(
            label: "Saved Password",
            username: "saved-user",
            kind: .password,
            password: "fixture-saved-login-value",
            elevationPassword: "fixture-saved-elevation-value"
        )
        var fields = QuickConnectCredentialFields(credential: credential)

        XCTAssertEqual(fields.username, "saved-user")
        XCTAssertEqual(fields.authentication, .password)
        XCTAssertEqual(fields.password, "fixture-saved-login-value")
        XCTAssertEqual(fields.elevationPassword, "fixture-saved-elevation-value")

        fields.username = "edited-user"
        fields.password = "fixture-edited-login-value"
        let host = AppState.makeQuickConnectHost(
            hostname: "host.example.invalid",
            port: 22,
            username: fields.username,
            authentication: fields.authentication,
            identityFile: nil,
            identityKey: nil,
            publicKey: nil,
            certificate: nil,
            passphrase: nil,
            password: fields.password,
            elevationPassword: fields.elevationPassword,
            credentialID: nil,
            serverToolsUseRoot: true,
            serverToolsElevationMethod: .sudo
        )

        XCTAssertEqual(host.username, "edited-user")
        XCTAssertEqual(host.password, "fixture-edited-login-value")
        XCTAssertEqual(host.elevationPassword, "fixture-saved-elevation-value")
        XCTAssertNil(host.credentialID)
    }

    func testQuickConnectPrivateKeyCredentialUsesEditedFields() {
        let credential = SSHCredential(
            label: "Saved Key",
            username: "saved-user",
            kind: .identityKey,
            privateKey: "fixture-saved-key-material",
            publicKey: "saved-public-key",
            certificate: "saved-certificate",
            passphrase: "fixture-saved-passphrase-value",
            savesPassphrase: true
        )
        var fields = QuickConnectCredentialFields(credential: credential)

        XCTAssertEqual(fields.username, "saved-user")
        XCTAssertEqual(fields.authentication, .identityFile)
        XCTAssertEqual(fields.identityKey, "fixture-saved-key-material")
        XCTAssertEqual(fields.publicKey, "saved-public-key")
        XCTAssertEqual(fields.certificate, "saved-certificate")
        XCTAssertEqual(fields.passphrase, "fixture-saved-passphrase-value")

        fields.username = "edited-user"
        fields.identityKey = "fixture-edited-key-material"
        fields.publicKey = "edited-public-key"
        fields.certificate = "edited-certificate"
        fields.passphrase = "fixture-edited-passphrase-value"
        let host = AppState.makeQuickConnectHost(
            hostname: "host.example.invalid",
            port: 22,
            username: fields.username,
            authentication: fields.authentication,
            identityFile: nil,
            identityKey: fields.identityKey,
            publicKey: fields.publicKey,
            certificate: fields.certificate,
            passphrase: fields.passphrase,
            password: nil,
            elevationPassword: nil,
            credentialID: nil,
            serverToolsUseRoot: false,
            serverToolsElevationMethod: .sudo
        )

        XCTAssertEqual(host.username, "edited-user")
        XCTAssertEqual(host.identityKey, "fixture-edited-key-material")
        XCTAssertEqual(host.publicKey, "edited-public-key")
        XCTAssertEqual(host.certificate, "edited-certificate")
        XCTAssertEqual(host.passphrase, "fixture-edited-passphrase-value")
        XCTAssertNil(host.credentialID)
    }

    @MainActor
    func testSessionHostFallsBackToQuickConnectDescriptor() throws {
        let hostID = QuickConnectHostIdentity.id(
            hostname: "host.example.invalid",
            port: 2200,
            username: "pilot"
        )
        let descriptor = SessionDescriptor(
            kind: .ssh,
            title: "host.example.invalid",
            hostID: hostID,
            hostname: "host.example.invalid",
            port: 2200,
            username: "pilot",
            authentication: .identityFile,
            identityFile: "/tmp/id_ed25519",
            sftpFileProtocol: .sftp,
            sftpFilenameEncoding: .utf8,
            sftpUsesSudo: true,
            sftpFollowsTerminalCWD: true,
            serverToolsUseRoot: true,
            serverToolsElevationMethod: .su,
            sshConnectionID: UUID()
        )
        let state = AppState()

        let host = try XCTUnwrap(state.sessionHost(for: descriptor))
        XCTAssertEqual(host.id, hostID)
        XCTAssertEqual(host.hostname, "host.example.invalid")
        XCTAssertEqual(host.port, 2200)
        XCTAssertEqual(host.username, "pilot")
        XCTAssertEqual(host.authentication, .identityFile)
        XCTAssertEqual(host.identityFile, "/tmp/id_ed25519")
        XCTAssertEqual(host.sftpFileProtocol, .sftp)
        XCTAssertEqual(host.sftpFilenameEncoding, .utf8)
        XCTAssertTrue(host.sftpUsesSudo)
        XCTAssertEqual(host.sftpFollowsTerminalCWD, true)
        XCTAssertTrue(host.serverToolsUseRoot)
        XCTAssertEqual(host.serverToolsElevationMethod, .su)
    }

    func testOpenSSHCredentialTextNormalizesEscapedPrivateKeyContent() {
        let raw = #""-----BEGIN OPENSSH PRIVATE KEY-----\nabc123\n-----END OPENSSH PRIVATE KEY-----""#

        XCTAssertEqual(
            OpenSSHCredentialText.normalizedFileContent(raw),
            """
            -----BEGIN OPENSSH PRIVATE KEY-----
            abc123
            -----END OPENSSH PRIVATE KEY-----

            """
        )
    }

    func testPortForwardEndpointParsesCombinedAddressAndPort() throws {
        XCTAssertEqual(
            PortForwardEndpoint.parse("127.0.0.1:8080"),
            PortForwardEndpoint(host: "127.0.0.1", port: 8080)
        )
        XCTAssertEqual(
            PortForwardEndpoint.parse(" 0.0.0.0:8,080 "),
            PortForwardEndpoint(host: "0.0.0.0", port: 8080)
        )
        XCTAssertNil(PortForwardEndpoint.parse("127.0.0.1"))
        XCTAssertNil(PortForwardEndpoint.parse("127.0.0.1:70000"))
    }

    func testRemotePortForwardMapsRemoteListenerToLocalTarget() {
        let rule = PortForwardRule(
            name: "Remote Forward",
            kind: .remote,
            bindAddress: "127.0.0.1",
            localPort: 8804,
            remoteHost: "127.0.0.1",
            remotePort: 8080
        )

        XCTAssertEqual(
            PortForwardOpenSSHArguments.forwardingArguments(for: rule),
            [
                "-N",
                "-o",
                "ExitOnForwardFailure=yes",
                "-R",
                "127.0.0.1:8080:127.0.0.1:8804",
            ]
        )
    }

    @MainActor
    func testNewWindowsCloneOnlyPreparedSourceAndRemainIndependent() async {
        let coordinator = WindowStateCoordinator()
        let firstWindow = AppState()
        let secondWindow = AppState()
        let thirdWindow = AppState()

        let firstBootstrap = coordinator.register(firstWindow)
        XCTAssertNil(firstBootstrap.initialWorkspaceSnapshot)

        await firstWindow.openLocalShell()
        let sourceSessionIDs = Set(firstWindow.sessions.keys)

        coordinator.prepareNextWindowClone(from: firstWindow)
        let secondBootstrap = coordinator.register(secondWindow)
        XCTAssertEqual(secondBootstrap.initialWorkspaceSnapshot?.workspaces.count, 1)
        XCTAssertEqual(secondBootstrap.initialWorkspaceSnapshot?.sessions.count, 1)
        let clonedSessionIDs = Set(
            secondBootstrap.initialWorkspaceSnapshot?.sessions.map(\.id) ?? []
        )
        XCTAssertFalse(clonedSessionIDs.isEmpty)
        XCTAssertTrue(sourceSessionIDs.isDisjoint(with: clonedSessionIDs))

        let repeatedFirstBootstrap = coordinator.register(firstWindow)
        XCTAssertNil(repeatedFirstBootstrap.initialWorkspaceSnapshot)

        await secondWindow.openLocalShell()
        await secondWindow.openLocalShell()

        let thirdBootstrap = coordinator.register(thirdWindow)
        XCTAssertNil(thirdBootstrap.initialWorkspaceSnapshot)

        let fourthWindow = AppState()
        coordinator.prepareNextWindowClone(from: firstWindow)
        let fourthBootstrap = coordinator.register(fourthWindow)
        XCTAssertEqual(fourthBootstrap.initialWorkspaceSnapshot?.sessions.count, 1)

        let fifthWindow = AppState()
        coordinator.prepareNextWindowClone(from: secondWindow)
        let fifthBootstrap = coordinator.register(fifthWindow)
        XCTAssertEqual(fifthBootstrap.initialWorkspaceSnapshot?.sessions.count, 2)
    }

    @MainActor
    func testNewWindowCloneUsesLastActiveWindowWhenFocusedStateIsMissing() async {
        let coordinator = WindowStateCoordinator()
        let sourceWindow = AppState()
        let emptyKeyWindow = AppState()
        let newWindow = AppState()

        _ = coordinator.register(sourceWindow)
        await sourceWindow.openLocalShell()

        coordinator.markActive(emptyKeyWindow)
        XCTAssertTrue(coordinator.prepareNextWindowClone(from: nil))

        let bootstrap = coordinator.register(newWindow)
        XCTAssertEqual(bootstrap.initialWorkspaceSnapshot?.workspaces.count, 1)
        XCTAssertEqual(bootstrap.initialWorkspaceSnapshot?.sessions.count, 1)
    }

    @MainActor
    func testDuplicateWorkspaceStartsClonedSessionsAutomatically() async throws {
        let state = AppState()
        await state.openLocalShell()
        let sourceWorkspace = try XCTUnwrap(state.activeWorkspace)
        let sourceSessionIDs = Set(sourceWorkspace.root.sessionIDs)

        await state.duplicateWorkspace(id: sourceWorkspace.id)

        let duplicate = try XCTUnwrap(state.activeWorkspace)
        let duplicateSessionIDs = Set(duplicate.root.sessionIDs)
        XCTAssertTrue(sourceSessionIDs.isDisjoint(with: duplicateSessionIDs))
        XCTAssertEqual(state.workspaces.count, 2)
        for sessionID in duplicateSessionIDs {
            let runtime = try XCTUnwrap(state.runtimes[sessionID])
            XCTAssertTrue(runtime.launchRequested)
            XCTAssertEqual(runtime.lifecycle, .connecting)
        }
    }

    @MainActor
    func testImmediateWindowTerminationClearsAllSessions() async throws {
        let state = AppState()
        await state.openLocalShell()
        let runtime = try XCTUnwrap(state.runtimes.values.first)

        state.terminateAllSessionsImmediately()

        XCTAssertEqual(runtime.lifecycle, .disconnected)
        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertTrue(state.runtimes.isEmpty)
        XCTAssertTrue(state.workspaces.isEmpty)
        XCTAssertNil(state.activeWorkspaceID)
    }

    func testPrivateKeyElevationPasswordResolvesForQuickFill() {
        let credential = SSHCredential(
            label: "Production Key",
            username: "alice",
            kind: .identityKey,
            privateKey: "fixture-key-material",
            elevationPassword: "fixture-elevation-value"
        )
        let host = TermPilotDomain.Host(
            label: "Production",
            hostname: "host.example.invalid",
            username: "alice",
            authentication: .identityFile,
            credentialID: credential.id
        )

        XCTAssertEqual(
            PasswordPromptQuickFillResolver.password(
                for: host,
                credentials: [credential]
            ),
            "fixture-elevation-value"
        )
        XCTAssertNil(
            PasswordPromptQuickFillResolver.password(
                for: host,
                credentials: []
            )
        )

        let passwordCredential = SSHCredential(
            label: "Password Login",
            username: "alice",
            kind: .password,
            password: "fixture-login-value",
            elevationPassword: "fixture-elevation-value"
        )
        var passwordHost = host
        passwordHost.authentication = .password
        passwordHost.credentialID = passwordCredential.id
        passwordHost.password = "fixture-login-value"
        XCTAssertEqual(
            PasswordPromptQuickFillResolver.password(
                for: passwordHost,
                credentials: [passwordCredential]
            ),
            "fixture-elevation-value"
        )

        passwordHost.elevationPassword = "fixture-quick-connect-elevation-value"
        XCTAssertEqual(
            PasswordPromptQuickFillResolver.password(
                for: passwordHost,
                credentials: [passwordCredential]
            ),
            "fixture-quick-connect-elevation-value"
        )
    }

    func testSavedProxyAndCredentialResolveBeforeConnection() throws {
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

        let resolved = try host.applyingConnectionSettings(
            credentials: [credential],
            proxyProfiles: [profile]
        )

        XCTAssertEqual(resolved.proxyConfiguration?.type, .http)
        XCTAssertEqual(resolved.proxyConfiguration?.username, "proxy-user")
        XCTAssertEqual(resolved.proxyConfiguration?.password, "fixture-proxy-value")
    }

    func testMissingSavedProxyDoesNotFallBackToDirectConnection() {
        var host = Fixtures.host()
        host.proxyProfileID = UUID()

        XCTAssertThrowsError(
            try host.applyingConnectionSettings(
                credentials: [],
                proxyProfiles: []
            )
        ) { error in
            guard let appStateError = error as? AppStateError,
                  case .invalidProxyProfile = appStateError
            else {
                return XCTFail("Expected invalidProxyProfile, got \(error)")
            }
        }
    }

    @MainActor
    func testOpenTerminalTabAddsSessionInsideCurrentPane() async throws {
        let state = AppState()
        await state.openLocalShell()
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let firstSessionID = workspace.focusedSessionID

        let openedSessionID = await state.openTerminalTab(
            from: firstSessionID,
            in: workspace.id,
            title: "Docker Logs"
        )

        let updated = try XCTUnwrap(state.activeWorkspace)
        XCTAssertEqual(updated.root.sessionIDs.count, 2)
        XCTAssertEqual(state.workspaces.count, 1)
        guard case let .tabGroup(_, sessionIDs, activeSessionID) = updated.root else {
            return XCTFail("Expected terminal tab group")
        }
        XCTAssertEqual(sessionIDs.first, firstSessionID)
        XCTAssertEqual(activeSessionID, sessionIDs.last)
        XCTAssertEqual(openedSessionID, activeSessionID)
        XCTAssertEqual(
            openedSessionID.flatMap { state.sessions[$0]?.title },
            "Docker Logs"
        )
    }

    @MainActor
    func testTerminalTabSelectionAndClosePreserveRemainingRuntime() async throws {
        let state = AppState()
        await state.openLocalShell()
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let firstSessionID = workspace.focusedSessionID
        let firstRuntime = try XCTUnwrap(state.runtimes[firstSessionID])
        let firstTerminalView = firstRuntime.view()
        let openedSessionID = await state.openTerminalTab(
            from: firstSessionID,
            in: workspace.id
        )
        let secondSessionID = try XCTUnwrap(openedSessionID)
        let secondRuntime = try XCTUnwrap(state.runtimes[secondSessionID])

        state.selectTerminalTab(
            sessionID: firstSessionID,
            workspaceID: workspace.id
        )
        guard case let .tabGroup(_, _, selectedSessionID) =
            state.activeWorkspace?.root
        else {
            return XCTFail("Expected terminal tab group")
        }
        XCTAssertEqual(selectedSessionID, firstSessionID)
        XCTAssertEqual(state.activeWorkspace?.focusedSessionID, firstSessionID)
        XCTAssertTrue(state.runtimes[firstSessionID] === firstRuntime)
        XCTAssertTrue(state.runtimes[secondSessionID] === secondRuntime)

        state.selectTerminalTab(
            sessionID: secondSessionID,
            workspaceID: workspace.id
        )
        await state.close(
            sessionID: secondSessionID,
            in: workspace.id
        )

        guard case let .pane(_, remainingSessionID) =
            state.activeWorkspace?.root
        else {
            return XCTFail("Expected remaining terminal pane")
        }
        XCTAssertEqual(remainingSessionID, firstSessionID)
        XCTAssertEqual(state.activeWorkspace?.focusedSessionID, firstSessionID)
        XCTAssertTrue(state.runtimes[firstSessionID] === firstRuntime)
        XCTAssertTrue(firstRuntime.view() === firstTerminalView)
        XCTAssertNil(state.runtimes[secondSessionID])
    }

    @MainActor
    func testAdditionalTerminalTabSuppressesAutomaticSystemOverview() async throws {
        let state = AppState()
        await state.openLocalShell()
        let workspace = try XCTUnwrap(state.activeWorkspace)

        let openedSessionID = await state.openTerminalTab(
            from: workspace.focusedSessionID,
            in: workspace.id,
            title: "Additional Shell"
        )
        let commandSessionID = try XCTUnwrap(openedSessionID)

        XCTAssertFalse(
            state.allowsAutomaticSystemOverview(for: commandSessionID)
        )

        await state.close(
            sessionID: commandSessionID,
            in: workspace.id
        )
        XCTAssertTrue(
            state.allowsAutomaticSystemOverview(for: commandSessionID)
        )
    }

    @MainActor
    func testSystemMonitorTabPersistsUntilWorkspaceCloses() async throws {
        let state = AppState()
        await state.openLocalShell()
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let sessionID = workspace.focusedSessionID

        state.selectTerminalSystemMonitorTab(
            "docker",
            in: workspace.id
        )
        XCTAssertEqual(
            state.terminalSystemMonitorTab(in: workspace.id),
            "docker"
        )

        await state.close(
            sessionID: sessionID,
            in: workspace.id
        )
        XCTAssertEqual(
            state.terminalSystemMonitorTab(in: workspace.id),
            "overview"
        )
    }

    @MainActor
    func testTerminalTabsCanMoveWithinWorkspace() async throws {
        let state = AppState()
        await state.openLocalShell()
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let firstSessionID = workspace.focusedSessionID
        await state.openTerminalTab(
            from: firstSessionID,
            in: workspace.id
        )
        await state.openTerminalTab(
            from: firstSessionID,
            in: workspace.id
        )

        let before = try XCTUnwrap(state.activeWorkspace)
        let originalIDs = before.root.sessionIDs
        state.moveTerminalTab(
            sessionID: originalIDs[0],
            workspaceID: workspace.id,
            toIndex: originalIDs.count
        )

        let moved = try XCTUnwrap(state.activeWorkspace)
        XCTAssertEqual(
            moved.root.sessionIDs,
            [originalIDs[1], originalIDs[2], originalIDs[0]]
        )
        XCTAssertEqual(moved.focusedSessionID, before.focusedSessionID)
    }

    @MainActor
    func testTerminalTabCanSplitIntoPaneWithoutReplacingRuntime() async throws {
        let state = AppState()
        await state.openLocalShell()
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let firstSessionID = workspace.focusedSessionID
        let firstRuntime = try XCTUnwrap(state.runtimes[firstSessionID])
        await state.openTerminalTab(
            from: firstSessionID,
            in: workspace.id
        )

        let tabbedWorkspace = try XCTUnwrap(state.activeWorkspace)
        let secondSessionID = tabbedWorkspace.focusedSessionID
        let secondRuntime = try XCTUnwrap(state.runtimes[secondSessionID])
        state.openTerminalSidePanel(
            in: workspace.id,
            for: secondSessionID,
            tab: .system
        )

        let didSplit = await state.splitTerminalTab(
            sessionID: secondSessionID,
            workspaceID: workspace.id,
            nextTo: secondSessionID,
            axis: .horizontal,
            placement: .after
        )

        XCTAssertTrue(didSplit)
        XCTAssertFalse(
            state.isTerminalSidePanelVisible(in: workspace.id)
        )
        XCTAssertTrue(state.runtimes[firstSessionID] === firstRuntime)
        XCTAssertTrue(state.runtimes[secondSessionID] === secondRuntime)
        let splitWorkspace = try XCTUnwrap(state.activeWorkspace)
        XCTAssertEqual(splitWorkspace.focusedSessionID, secondSessionID)
        guard case let .split(_, axis, children, _) = splitWorkspace.root else {
            return XCTFail("Expected terminal tab split")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children[0].sessionIDs, [firstSessionID])
        XCTAssertEqual(children[1].sessionIDs, [secondSessionID])
    }

    @MainActor
    func testWorkspaceTabsCanMoveToRequestedIndex() async throws {
        let state = AppState()
        await state.openLocalShell()
        await state.openLocalShell()
        await state.openLocalShell()

        let ids = state.workspaces.map(\.id)
        XCTAssertEqual(ids.count, 3)

        state.moveWorkspace(id: ids[0], toIndex: 3)
        XCTAssertEqual(state.workspaces.map(\.id), [ids[1], ids[2], ids[0]])

        state.moveWorkspace(id: ids[0], toIndex: 0)
        XCTAssertEqual(state.workspaces.map(\.id), ids)
    }

    func testWorkspaceSplitDropResolverMatchesFourDropDirections() throws {
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)

        let left = try XCTUnwrap(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 20, y: 70),
                in: frame
            )
        )
        XCTAssertEqual(left.axis, .vertical)
        guard case .before = left.placement else {
            return XCTFail("Expected left drop before target")
        }
        XCTAssertEqual(
            left.previewFrame,
            CGRect(x: 10, y: 20, width: 100, height: 100)
        )

        let right = try XCTUnwrap(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 200, y: 70),
                in: frame
            )
        )
        XCTAssertEqual(right.axis, .vertical)
        guard case .after = right.placement else {
            return XCTFail("Expected right drop after target")
        }
        XCTAssertEqual(
            right.previewFrame,
            CGRect(x: 110, y: 20, width: 100, height: 100)
        )

        let top = try XCTUnwrap(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 110, y: 25),
                in: frame
            )
        )
        XCTAssertEqual(top.axis, .horizontal)
        guard case .before = top.placement else {
            return XCTFail("Expected top drop before target")
        }
        XCTAssertEqual(
            top.previewFrame,
            CGRect(x: 10, y: 20, width: 200, height: 50)
        )

        let bottom = try XCTUnwrap(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 110, y: 115),
                in: frame
            )
        )
        XCTAssertEqual(bottom.axis, .horizontal)
        guard case .after = bottom.placement else {
            return XCTFail("Expected bottom drop after target")
        }
        XCTAssertEqual(
            bottom.previewFrame,
            CGRect(x: 10, y: 70, width: 200, height: 50)
        )

        XCTAssertNil(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 0, y: 0),
                in: frame
            )
        )
    }

    func testWorkspaceSidePanelPublishesOnlyTerminalDropFrame() throws {
        let frame = try XCTUnwrap(
            WorkspaceSidePanelDropFrameResolver.contentFrame(
                containerFrame: CGRect(
                    x: 20,
                    y: 40,
                    width: 1_000,
                    height: 600
                ),
                contentWidth: 640
            )
        )

        XCTAssertEqual(
            frame,
            CGRect(x: 20, y: 73, width: 640, height: 567)
        )
        XCTAssertNotNil(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 30, y: 340),
                in: frame
            )
        )
        XCTAssertNotNil(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 650, y: 340),
                in: frame
            )
        )
        XCTAssertNotNil(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 340, y: 80),
                in: frame
            )
        )
        XCTAssertNotNil(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 340, y: 630),
                in: frame
            )
        )
        XCTAssertNil(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 900, y: 340),
                in: frame
            )
        )
        XCTAssertNil(
            WorkspaceSplitDropResolver.resolve(
                location: CGPoint(x: 340, y: 50),
                in: frame
            )
        )
    }

    func testTerminalSidePanelInitialLayoutKeepsSidebarAtDefaultWidth() {
        XCTAssertEqual(
            TerminalSidePanelDividerResolver.resolve(
                totalWidth: 992,
                dividerThickness: 1,
                terminalMinWidth: 360,
                sidebarMinWidth: 350,
                sidebarMaxWidth: 760,
                preferredContentWidth: nil
            ),
            641
        )
    }

    func testTerminalSidePanelInitialLayoutKeepsTerminalMinimumInNarrowWindow() {
        XCTAssertEqual(
            TerminalSidePanelDividerResolver.resolve(
                totalWidth: 680,
                dividerThickness: 1,
                terminalMinWidth: 360,
                sidebarMinWidth: 350,
                sidebarMaxWidth: 760,
                preferredContentWidth: nil
            ),
            360
        )
    }

    func testTerminalSidePanelDividerStaysInsideZeroWidthLayout() {
        XCTAssertEqual(
            TerminalSidePanelDividerResolver.resolve(
                totalWidth: 0,
                dividerThickness: 1,
                terminalMinWidth: 360,
                sidebarMinWidth: 350,
                sidebarMaxWidth: 760,
                preferredContentWidth: nil
            ),
            0
        )
    }

    func testTerminalSidePanelDividerEnforcesMaximumSidebarWidth() {
        XCTAssertEqual(
            TerminalSidePanelDividerResolver.resolve(
                totalWidth: 1_800,
                dividerThickness: 1,
                terminalMinWidth: 360,
                sidebarMinWidth: 350,
                sidebarMaxWidth: 760,
                preferredContentWidth: 500
            ),
            1_039
        )
    }

    func testTerminalTabSplitDragResolverUsesMeasuredTabFrames() {
        let tabFrames = [
            CGRect(x: 20, y: 40, width: 100, height: 24),
            CGRect(x: 125, y: 40, width: 100, height: 24),
        ]

        XCTAssertNil(
            TerminalTabSplitDragResolver.splitLocation(
                at: CGPoint(x: 150, y: 50),
                tabFrames: tabFrames
            )
        )
        XCTAssertEqual(
            TerminalTabSplitDragResolver.splitLocation(
                at: CGPoint(x: 150, y: 180),
                tabFrames: tabFrames
            ),
            CGPoint(x: 150, y: 180)
        )
        XCTAssertNil(
            TerminalTabSplitDragResolver.splitLocation(
                at: CGPoint(x: 150, y: 180),
                tabFrames: []
            )
        )
    }

    func testTerminalTabDragLocationNormalizesNestedHostingCoordinates() {
        let sourceFrame = CGRect(
            x: 240,
            y: 80,
            width: 100,
            height: 24
        )
        let translation = CGSize(width: 150, height: 2)
        let expected = CGPoint(x: 410, y: 94)

        XCTAssertEqual(
            TerminalTabDragLocationResolver.resolve(
                startLocation: CGPoint(x: 20, y: 12),
                location: CGPoint(x: 170, y: 14),
                translation: translation,
                sourceFrame: sourceFrame
            ),
            expected
        )
        XCTAssertEqual(
            TerminalTabDragLocationResolver.resolve(
                startLocation: CGPoint(x: 260, y: 92),
                location: expected,
                translation: translation,
                sourceFrame: sourceFrame
            ),
            expected
        )
        XCTAssertEqual(
            TerminalTabDragLocationResolver.resolve(
                startLocation: .zero,
                location: CGPoint(x: 30, y: 40),
                translation: .zero,
                sourceFrame: nil
            ),
            CGPoint(x: 30, y: 40)
        )
    }

    func testTerminalTabDropIndicatorUsesTabStripCoordinates() {
        XCTAssertEqual(
            TerminalTabDropIndicatorResolver.localX(
                rootX: 527.5,
                tabStripFrame: CGRect(
                    x: 284.5,
                    y: 95,
                    width: 500,
                    height: 32
                )
            ),
            243
        )
        XCTAssertEqual(
            TerminalTabDropIndicatorResolver.localX(
                rootX: 527.5,
                tabStripFrame: .zero
            ),
            527.5
        )
    }

    func testTerminalTabReorderResolverUsesVisualTabOrder() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabFrames = [
            first: CGRect(x: 20, y: 40, width: 100, height: 24),
            second: CGRect(x: 125, y: 40, width: 100, height: 24),
            third: CGRect(x: 230, y: 40, width: 100, height: 24),
        ]

        let firstAfterSecond = try XCTUnwrap(
            TerminalTabReorderResolver.resolve(
                sessionID: first,
                location: CGPoint(x: 200, y: 50),
                tabFrames: tabFrames
            )
        )
        XCTAssertEqual(firstAfterSecond.rawDestinationIndex, 2)
        XCTAssertEqual(firstAfterSecond.indicatorX, 230)

        let firstAtEnd = try XCTUnwrap(
            TerminalTabReorderResolver.resolve(
                sessionID: first,
                location: CGPoint(x: 320, y: 50),
                tabFrames: tabFrames
            )
        )
        XCTAssertEqual(firstAtEnd.rawDestinationIndex, 3)
        XCTAssertEqual(firstAtEnd.indicatorX, 330)

        let thirdAtStart = try XCTUnwrap(
            TerminalTabReorderResolver.resolve(
                sessionID: third,
                location: CGPoint(x: 40, y: 50),
                tabFrames: tabFrames
            )
        )
        XCTAssertEqual(thirdAtStart.rawDestinationIndex, 0)
        XCTAssertEqual(thirdAtStart.indicatorX, 20)

        XCTAssertNil(
            TerminalTabReorderResolver.resolve(
                sessionID: second,
                location: CGPoint(x: 175, y: 50),
                tabFrames: tabFrames
            )
        )
    }

    func testWorkspacePaneDetachDropResolverMatchesTabInsertionPosition() throws {
        let tabBarFrame = CGRect(x: 0, y: 0, width: 400, height: 40)
        let tabFrames = [
            CGRect(x: 10, y: 5, width: 100, height: 30),
            CGRect(x: 120, y: 5, width: 100, height: 30),
        ]

        let beforeFirst = try XCTUnwrap(
            WorkspacePaneDetachDropResolver.resolve(
                location: CGPoint(x: 20, y: 20),
                tabBarFrame: tabBarFrame,
                tabFrames: tabFrames
            )
        )
        XCTAssertEqual(beforeFirst.insertionIndex, 0)
        XCTAssertEqual(beforeFirst.indicatorX, 10)

        let afterFirst = try XCTUnwrap(
            WorkspacePaneDetachDropResolver.resolve(
                location: CGPoint(x: 100, y: 20),
                tabBarFrame: tabBarFrame,
                tabFrames: tabFrames
            )
        )
        XCTAssertEqual(afterFirst.insertionIndex, 1)
        XCTAssertEqual(afterFirst.indicatorX, 110)

        let afterLast = try XCTUnwrap(
            WorkspacePaneDetachDropResolver.resolve(
                location: CGPoint(x: 300, y: 20),
                tabBarFrame: tabBarFrame,
                tabFrames: tabFrames
            )
        )
        XCTAssertEqual(afterLast.insertionIndex, 2)
        XCTAssertEqual(afterLast.indicatorX, 220)

        XCTAssertNil(
            WorkspacePaneDetachDropResolver.resolve(
                location: CGPoint(x: 200, y: 60),
                tabBarFrame: tabBarFrame,
                tabFrames: tabFrames
            )
        )
    }

    @MainActor
    func testStandaloneWorkspaceMergesIntoTargetWithoutReplacingSessions() async throws {
        let state = AppState()
        await state.openLocalShell()
        let targetWorkspace = try XCTUnwrap(state.activeWorkspace)
        let targetSessionID = targetWorkspace.focusedSessionID
        let targetRuntime = try XCTUnwrap(state.runtimes[targetSessionID])

        await state.openLocalShell()
        let sourceWorkspace = try XCTUnwrap(state.activeWorkspace)
        let sourceSessionID = sourceWorkspace.focusedSessionID
        let sourceRuntime = try XCTUnwrap(state.runtimes[sourceSessionID])

        for (workspaceID, sessionID) in [
            (targetWorkspace.id, targetSessionID),
            (sourceWorkspace.id, sourceSessionID),
        ] {
            state.openTerminalSidePanel(
                in: workspaceID,
                for: sessionID,
                tab: .system
            )
        }

        let merged = await state.mergeWorkspace(
            sourceWorkspaceID: sourceWorkspace.id,
            into: targetWorkspace.id,
            nextTo: targetSessionID,
            axis: .vertical,
            placement: .before
        )

        XCTAssertTrue(merged)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.activeWorkspaceID, targetWorkspace.id)
        XCTAssertTrue(state.runtimes[targetSessionID] === targetRuntime)
        XCTAssertTrue(state.runtimes[sourceSessionID] === sourceRuntime)
        XCTAssertFalse(
            state.isTerminalSidePanelVisible(in: targetWorkspace.id)
        )
        XCTAssertFalse(
            state.isTerminalSidePanelVisible(in: sourceWorkspace.id)
        )

        let workspace = try XCTUnwrap(state.activeWorkspace)
        XCTAssertEqual(workspace.root.paneCount, 2)
        XCTAssertEqual(workspace.focusedSessionID, targetSessionID)
        guard case let .split(_, axis, children, _) = workspace.root else {
            return XCTFail("Expected merged split workspace")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(children[0].sessionIDs, [sourceSessionID])
        XCTAssertEqual(children[1].sessionIDs, [targetSessionID])

        await state.openLocalShell()
        let additionalWorkspace = try XCTUnwrap(state.activeWorkspace)
        let additionalSessionID = additionalWorkspace.focusedSessionID
        let additionalRuntime = try XCTUnwrap(
            state.runtimes[additionalSessionID]
        )

        let expanded = await state.mergeWorkspace(
            sourceWorkspaceID: additionalWorkspace.id,
            into: targetWorkspace.id,
            nextTo: sourceSessionID,
            axis: .horizontal,
            placement: .after
        )

        XCTAssertTrue(expanded)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertTrue(state.runtimes[additionalSessionID] === additionalRuntime)
        let expandedWorkspace = try XCTUnwrap(state.activeWorkspace)
        XCTAssertEqual(expandedWorkspace.root.paneCount, 3)
        guard case let .split(_, rootAxis, rootChildren, _) =
            expandedWorkspace.root,
            case let .split(_, nestedAxis, nestedChildren, _) =
                rootChildren[0]
        else {
            return XCTFail("Expected nested split workspace")
        }
        XCTAssertEqual(rootAxis, .vertical)
        XCTAssertEqual(nestedAxis, .horizontal)
        XCTAssertEqual(nestedChildren[0].sessionIDs, [sourceSessionID])
        XCTAssertEqual(nestedChildren[1].sessionIDs, [additionalSessionID])
        XCTAssertEqual(rootChildren[1].sessionIDs, [targetSessionID])

        let detached = state.detachPane(
            containing: additionalSessionID,
            from: targetWorkspace.id,
            toIndex: 0
        )

        XCTAssertTrue(detached)
        XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertEqual(
            state.workspaces[0].root.sessionIDs,
            [additionalSessionID]
        )
        XCTAssertEqual(state.activeWorkspaceID, state.workspaces[0].id)
        XCTAssertTrue(state.runtimes[additionalSessionID] === additionalRuntime)
        let remainingWorkspace = try XCTUnwrap(
            state.workspaces.first { $0.id == targetWorkspace.id }
        )
        XCTAssertEqual(remainingWorkspace.root.paneCount, 2)
        XCTAssertEqual(
            Set(remainingWorkspace.root.sessionIDs),
            Set([sourceSessionID, targetSessionID])
        )
    }

    @MainActor
    func testTabbedTopWorkspaceMergesAsSinglePane() async throws {
        let state = AppState()
        await state.openLocalShell()
        let targetWorkspace = try XCTUnwrap(state.activeWorkspace)
        let targetSessionID = targetWorkspace.focusedSessionID
        let targetRuntime = try XCTUnwrap(state.runtimes[targetSessionID])

        await state.openLocalShell()
        let sourceWorkspace = try XCTUnwrap(state.activeWorkspace)
        let firstTabID = sourceWorkspace.focusedSessionID
        let firstTabRuntime = try XCTUnwrap(state.runtimes[firstTabID])
        await state.openTerminalTab(
            from: firstTabID,
            in: sourceWorkspace.id
        )
        let tabbedSource = try XCTUnwrap(state.activeWorkspace)
        let secondTabID = tabbedSource.focusedSessionID
        let secondTabRuntime = try XCTUnwrap(state.runtimes[secondTabID])

        let merged = await state.mergeWorkspace(
            sourceWorkspaceID: sourceWorkspace.id,
            into: targetWorkspace.id,
            nextTo: targetSessionID,
            axis: .vertical,
            placement: .after
        )

        XCTAssertTrue(merged)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.activeWorkspaceID, targetWorkspace.id)
        XCTAssertTrue(state.runtimes[targetSessionID] === targetRuntime)
        XCTAssertTrue(state.runtimes[firstTabID] === firstTabRuntime)
        XCTAssertTrue(state.runtimes[secondTabID] === secondTabRuntime)

        let workspace = try XCTUnwrap(state.activeWorkspace)
        XCTAssertEqual(workspace.root.paneCount, 2)
        guard case let .split(_, axis, children, _) = workspace.root,
              case let .tabGroup(_, tabIDs, activeTabID) = children[1]
        else {
            return XCTFail("Expected source tab group in merged split")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(children[0].sessionIDs, [targetSessionID])
        XCTAssertEqual(tabIDs, [firstTabID, secondTabID])
        XCTAssertEqual(activeTabID, secondTabID)
    }

    @MainActor
    func testDetachPaneMovesTerminalTabGroupTogether() async throws {
        let state = AppState()
        await state.openLocalShell()
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let firstSessionID = workspace.focusedSessionID
        let firstRuntime = try XCTUnwrap(state.runtimes[firstSessionID])

        await state.openTerminalTab(
            from: firstSessionID,
            in: workspace.id
        )
        let tabbedWorkspace = try XCTUnwrap(state.activeWorkspace)
        let secondSessionID = tabbedWorkspace.focusedSessionID
        let secondRuntime = try XCTUnwrap(state.runtimes[secondSessionID])

        await state.openSiblingTerminal(
            from: secondSessionID,
            splitAxis: .vertical
        )
        let splitWorkspace = try XCTUnwrap(state.activeWorkspace)
        let otherPaneSessionID = splitWorkspace.focusedSessionID
        XCTAssertEqual(splitWorkspace.root.paneCount, 2)

        let detached = state.detachPane(
            containing: secondSessionID,
            from: workspace.id,
            toIndex: 0
        )

        XCTAssertTrue(detached)
        XCTAssertEqual(state.workspaces.count, 2)
        let detachedWorkspace = state.workspaces[0]
        XCTAssertEqual(
            detachedWorkspace.root.sessionIDs,
            [firstSessionID, secondSessionID]
        )
        XCTAssertEqual(detachedWorkspace.focusedSessionID, secondSessionID)
        guard case .tabGroup = detachedWorkspace.root else {
            return XCTFail("Expected detached terminal tab group")
        }
        let remainingWorkspace = try XCTUnwrap(
            state.workspaces.first { $0.id == workspace.id }
        )
        XCTAssertEqual(
            remainingWorkspace.root.sessionIDs,
            [otherPaneSessionID]
        )
        XCTAssertTrue(state.runtimes[firstSessionID] === firstRuntime)
        XCTAssertTrue(state.runtimes[secondSessionID] === secondRuntime)
    }

    func testTerminalSidePanelConnectionIdentityUsesSSHTransport() {
        let host = Fixtures.host()
        let connectionID = UUID()
        let first = SessionDescriptor.ssh(
            host: host,
            connectionID: connectionID
        )
        let sibling = SessionDescriptor.ssh(
            host: host,
            connectionID: connectionID
        )
        let independent = SessionDescriptor.ssh(
            host: host,
            connectionID: UUID()
        )
        let local = SessionDescriptor.local(
            shell: "/bin/zsh",
            workingDirectory: "/tmp"
        )

        XCTAssertTrue(
            AppState.terminalSidePanelDescriptorsShareConnection(
                first,
                sibling
            )
        )
        XCTAssertFalse(
            AppState.terminalSidePanelDescriptorsShareConnection(
                first,
                independent
            )
        )
        XCTAssertFalse(
            AppState.terminalSidePanelDescriptorsShareConnection(
                first,
                local
            )
        )
    }

    @MainActor
    func testSFTPBrowserShowsHiddenEntriesByDefault() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(
            forKey: SFTPPreferences.showsHiddenFilesKey
        )
        defaults.removeObject(forKey: SFTPPreferences.showsHiddenFilesKey)
        defer {
            if let previous {
                defaults.set(
                    previous,
                    forKey: SFTPPreferences.showsHiddenFilesKey
                )
            } else {
                defaults.removeObject(
                    forKey: SFTPPreferences.showsHiddenFilesKey
                )
            }
        }
        let model = SFTPBrowserModel(host: Fixtures.host())

        XCTAssertTrue(model.showsHiddenFiles)
    }

    @MainActor
    func testSFTPBrowserDefaultsToSystemDownloadsDirectory() {
        let model = SFTPBrowserModel(host: Fixtures.host())
        let expected = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        XCTAssertEqual(
            model.localPath.standardizedFileURL,
            expected.standardizedFileURL
        )
    }

    func testSFTPPreferencesNormalizeTransferSettings() {
        XCTAssertEqual(
            SFTPPreferences.clampedFileTransferConcurrency(0),
            1
        )
        XCTAssertEqual(
            SFTPPreferences.clampedFileTransferConcurrency(99),
            16
        )
        XCTAssertEqual(SFTPPreferences.clampedChunkConcurrency(0), 1)
        XCTAssertEqual(SFTPPreferences.clampedChunkConcurrency(99), 32)
        XCTAssertEqual(
            SFTPPreferences.normalizedChunkSizeBytes(5 * 1_024 * 1_024),
            5 * 1_024 * 1_024
        )
        XCTAssertEqual(
            SFTPPreferences.normalizedChunkSizeBytes(123),
            SFTPPreferences.defaultChunkSizeBytes
        )
        XCTAssertEqual(
            SFTPPreferences.normalizedTransferConnectionIdleSeconds(0),
            0
        )
        XCTAssertEqual(
            SFTPPreferences.normalizedTransferConnectionIdleSeconds(123),
            SFTPPreferences.defaultTransferConnectionIdleSeconds
        )
    }

    @MainActor
    func testSFTPBrowserAddsParentDirectoryOutsideRoot() {
        let model = SFTPBrowserModel(host: Fixtures.host())
        model.remotePathText = "/srv/app"
        model.remoteEntries = [
            SFTPDirectoryEntry(name: "logs", kind: .directory),
            SFTPDirectoryEntry(name: "app.log", kind: .file),
        ]

        XCTAssertEqual(
            model.visibleRemoteEntries.map(\.name),
            ["..", "logs", "app.log"]
        )

        model.remoteFilterText = "missing"
        XCTAssertEqual(model.visibleRemoteEntries.map(\.name), [".."])

        model.remotePathText = "/"
        XCTAssertFalse(
            model.visibleRemoteEntries.contains(where: { $0.name == ".." })
        )
    }

    @MainActor
    func testSFTPInvalidationClearsStaleConnectionState() {
        let model = SFTPBrowserModel(host: Fixtures.host())
        model.isConnected = true
        model.isConnecting = true
        model.isRemoteLoading = true

        model.invalidateRemoteConnection()

        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isConnecting)
        XCTAssertFalse(model.isRemoteLoading)
    }

    @MainActor
    func testWorkspaceSwitchPreservesIndependentSidePanelConnections() async throws {
        let state = AppState()
        await state.openLocalShell()
        let firstWorkspace = try XCTUnwrap(state.activeWorkspace)
        state.openTerminalSidePanel(
            in: firstWorkspace.id,
            for: firstWorkspace.focusedSessionID,
            tab: .sftp
        )
        let firstModel = try XCTUnwrap(
            state.sftpSidePanelModel(in: firstWorkspace.id)
        )
        await firstModel.connect(using: state)

        await state.openLocalShell()
        let secondWorkspace = try XCTUnwrap(state.activeWorkspace)
        state.openTerminalSidePanel(
            in: secondWorkspace.id,
            for: secondWorkspace.focusedSessionID,
            tab: .sftp
        )
        let secondModel = try XCTUnwrap(
            state.sftpSidePanelModel(in: secondWorkspace.id)
        )
        await secondModel.connect(using: state)

        XCTAssertFalse(firstModel === secondModel)
        state.activeWorkspaceID = firstWorkspace.id
        XCTAssertTrue(
            firstModel === state.sftpSidePanelModel(in: firstWorkspace.id)
        )
        XCTAssertTrue(firstModel.isConnected)
        XCTAssertTrue(secondModel.isConnected)

        state.activeWorkspaceID = secondWorkspace.id
        XCTAssertTrue(
            secondModel === state.sftpSidePanelModel(in: secondWorkspace.id)
        )
        XCTAssertTrue(firstModel.isConnected)
        XCTAssertTrue(secondModel.isConnected)
    }

    @MainActor
    func testTerminalSidePanelIsSharedAcrossWorkspaceTabs() async throws {
        let state = AppState()
        await state.openLocalShell()
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let firstSessionID = workspace.focusedSessionID

        state.openTerminalSidePanel(
            in: workspace.id,
            for: firstSessionID,
            tab: .sftp
        )
        state.selectTerminalSystemMonitorTab(
            "docker",
            in: workspace.id
        )
        XCTAssertTrue(state.isTerminalSidePanelVisible(in: workspace.id))
        let sftpModel = try XCTUnwrap(
            state.sftpSidePanelModel(in: workspace.id)
        )
        let historyModel = try XCTUnwrap(
            state.commandHistoryModel(in: workspace.id)
        )
        XCTAssertEqual(
            state.terminalSidePanelSourceSessionID(in: workspace.id),
            firstSessionID
        )
        XCTAssertEqual(
            state.terminalSidePanelSessionID(in: workspace.id),
            firstSessionID
        )
        let sidePanelUpdateID = state.terminalSidePanelUpdateID(
            in: workspace.id
        )

        await state.openTerminalTab(from: firstSessionID, in: workspace.id)
        let updated = try XCTUnwrap(state.activeWorkspace)
        let secondSessionID = try XCTUnwrap(
            updated.root.sessionIDs.first { $0 != firstSessionID }
        )

        XCTAssertEqual(updated.focusedSessionID, secondSessionID)
        XCTAssertTrue(state.isTerminalSidePanelVisible(in: workspace.id))
        XCTAssertTrue(
            sftpModel === state.sftpSidePanelModel(in: workspace.id)
        )
        XCTAssertTrue(
            historyModel === state.commandHistoryModel(in: workspace.id)
        )
        XCTAssertEqual(
            state.terminalSystemMonitorTab(in: workspace.id),
            "docker"
        )
        XCTAssertEqual(
            state.terminalSidePanelSourceSessionID(in: workspace.id),
            firstSessionID
        )
        XCTAssertEqual(
            state.terminalSidePanelSessionID(in: workspace.id),
            secondSessionID
        )

        await state.close(sessionID: firstSessionID, in: workspace.id)
        XCTAssertTrue(state.isTerminalSidePanelVisible(in: workspace.id))
        XCTAssertTrue(
            sftpModel === state.sftpSidePanelModel(in: workspace.id)
        )
        XCTAssertEqual(
            state.activeWorkspace?.focusedSessionID,
            secondSessionID
        )
        XCTAssertEqual(
            state.terminalSidePanelSourceSessionID(in: workspace.id),
            secondSessionID
        )
        XCTAssertEqual(
            state.terminalSidePanelUpdateID(in: workspace.id),
            sidePanelUpdateID
        )

        await state.close(sessionID: secondSessionID, in: workspace.id)
        XCTAssertFalse(state.isTerminalSidePanelVisible(in: workspace.id))
        XCTAssertNil(state.sftpSidePanelModel(in: workspace.id))
        XCTAssertNil(state.commandHistoryModel(in: workspace.id))
        XCTAssertNil(
            state.terminalSidePanelSourceSessionID(in: workspace.id)
        )
    }

    @MainActor
    func testCreatingSplitClosesWorkspaceSidePanel() async throws {
        for axis in [SplitAxis.horizontal, .vertical] {
            let state = AppState()
            await state.openLocalShell()

            let workspace = try XCTUnwrap(state.activeWorkspace)
            let sessionID = workspace.focusedSessionID

            state.openTerminalSidePanel(
                in: workspace.id,
                for: sessionID,
                tab: .system
            )
            XCTAssertTrue(
                state.isTerminalSidePanelVisible(in: workspace.id)
            )

            await state.openSiblingTerminal(
                from: sessionID,
                splitAxis: axis
            )

            XCTAssertFalse(
                state.isTerminalSidePanelVisible(in: workspace.id)
            )
            XCTAssertNil(state.sftpSidePanelModel(in: workspace.id))
            XCTAssertEqual(state.activeWorkspace?.root.sessionIDs.count, 2)
        }
    }

    @MainActor
    func testLocalTerminalSidePanelUsesLocalFilesystemDataSource() async throws {
        let state = AppState()
        await state.openLocalShell()

        let workspace = try XCTUnwrap(state.activeWorkspace)
        let sessionID = workspace.focusedSessionID
        let descriptor = try XCTUnwrap(state.sessions[sessionID])
        let host = try XCTUnwrap(state.sessionHost(for: descriptor))

        XCTAssertEqual(descriptor.kind, .local)
        XCTAssertEqual(host.distro, .macos)
        XCTAssertEqual(
            TerminalSidePanelTab.available(for: .local),
            [.sftp, .system, .scripts, .history, .notes]
        )
        XCTAssertTrue(
            TerminalSidePanelTab.available(for: .ssh).contains(.forwarding)
        )

        state.openTerminalSidePanel(
            in: workspace.id,
            for: sessionID,
            tab: .sftp
        )

        let model = try XCTUnwrap(
            state.sftpSidePanelModel(in: workspace.id)
        )
        XCTAssertTrue(model.usesLocalFilesystemOnly)
        XCTAssertEqual(
            model.localPath.path,
            try XCTUnwrap(descriptor.workingDirectory)
        )

        await model.connect(using: state)
        XCTAssertTrue(model.isConnected)
        XCTAssertNil(model.errorMessage)

        let historyModel = try XCTUnwrap(
            state.commandHistoryModel(in: workspace.id)
        )
        guard case .local(let shell) = historyModel.dataSource else {
            return XCTFail("Expected local command history data source")
        }
        XCTAssertEqual(shell, descriptor.shell)
    }

    @MainActor
    func testFileTransferProgressTracksRateAndPauseStopsRate() throws {
        let state = AppState()
        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        state.recordFileTransfer(
            FileTransferRecord(
                id: id,
                kind: .upload,
                name: "archive.zip",
                sourcePath: "/tmp/archive.zip",
                destinationPath: "/root/archive.zip",
                startedAt: startedAt
            )
        )

        state.updateFileTransfer(
            id: id,
            bytesTransferred: 1_048_576,
            totalBytes: 2_097_152,
            at: startedAt.addingTimeInterval(1)
        )

        var record = try XCTUnwrap(state.fileTransfers.first)
        XCTAssertEqual(record.progressFraction, 0.5)
        XCTAssertEqual(record.bytesPerSecond, 1_048_576, accuracy: 0.1)

        state.setFileTransferStatus(id: id, status: .paused)
        record = try XCTUnwrap(state.fileTransfers.first)
        XCTAssertEqual(record.status, .paused)
        XCTAssertEqual(record.bytesPerSecond, 0)
        XCTAssertTrue(record.isUnfinished)

        state.setFileTransferStatus(id: id, status: .running)
        record = try XCTUnwrap(state.fileTransfers.first)
        XCTAssertEqual(record.status, .running)
        XCTAssertEqual(record.bytesTransferred, 1_048_576)
        XCTAssertEqual(record.progressFraction, 0.5)
    }

    @MainActor
    func testRestartingConflictReusesOriginalTransferRecord() throws {
        let state = AppState()
        let id = UUID()
        state.recordFileTransfer(
            FileTransferRecord(
                id: id,
                kind: .upload,
                name: "archive.iso",
                sourcePath: "/tmp/archive.iso",
                destinationPath: "/srv/archive.iso",
                bytesTransferred: 1_024,
                totalBytes: 8_192,
                status: .attention("already exists")
            )
        )

        state.restartFileTransfer(
            id: id,
            destinationPath: "/srv/archive (copy).iso",
            name: "archive (copy).iso"
        )

        XCTAssertEqual(state.fileTransfers.count, 1)
        let record = try XCTUnwrap(state.fileTransfers.first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.status, .running)
        XCTAssertEqual(record.name, "archive (copy).iso")
        XCTAssertEqual(record.destinationPath, "/srv/archive (copy).iso")
        XCTAssertEqual(record.bytesTransferred, 0)
        XCTAssertNil(record.totalBytes)
        XCTAssertNil(record.finishedAt)
    }

    func testBatchConflictSelectionsSupportBulkAndPerFileActions() {
        let batchID = UUID()
        let conflicts = [
            PendingSFTPOverwrite.upload(
                transferID: UUID(),
                batchID: batchID,
                localURL: URL(fileURLWithPath: "/tmp/first.txt"),
                remotePath: "/srv/first.txt",
                existingEntry: SFTPDirectoryEntry(
                    name: "first.txt",
                    kind: .file
                )
            ),
            PendingSFTPOverwrite.upload(
                transferID: UUID(),
                batchID: batchID,
                localURL: URL(fileURLWithPath: "/tmp/second.txt"),
                remotePath: "/srv/second.txt",
                existingEntry: SFTPDirectoryEntry(
                    name: "second.txt",
                    kind: .file
                )
            ),
        ]
        var selections = SFTPBatchConflictSelections(conflicts: conflicts)

        XCTAssertEqual(selections[conflicts[0].id], .skip)
        XCTAssertEqual(selections[conflicts[1].id], .skip)

        selections.applyToAll(.replace, conflicts: conflicts)

        XCTAssertEqual(selections.bulkResolution, .replace)
        XCTAssertEqual(selections[conflicts[0].id], .replace)
        XCTAssertEqual(selections[conflicts[1].id], .replace)

        selections.set(.duplicate, for: conflicts[1].id)

        XCTAssertEqual(selections[conflicts[0].id], .replace)
        XCTAssertEqual(selections[conflicts[1].id], .duplicate)
    }

    @MainActor
    func testUploadConflictQueueAppliesOnlyToMatchingBatchBucket() throws {
        let state = AppState()
        let model = SFTPBrowserModel(host: Fixtures.host())
        let batchID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let firstURL = root.appendingPathComponent("first.txt")
        let secondURL = root.appendingPathComponent("second.txt")
        let thirdURL = root.appendingPathComponent("folder-name")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        try Data("third".utf8).write(to: thirdURL)

        let conflicts = [
            PendingSFTPOverwrite.upload(
                transferID: UUID(),
                batchID: batchID,
                localURL: firstURL,
                remotePath: "/srv/first.txt",
                existingEntry: SFTPDirectoryEntry(
                    name: "first.txt",
                    kind: .file
                )
            ),
            PendingSFTPOverwrite.upload(
                transferID: UUID(),
                batchID: batchID,
                localURL: secondURL,
                remotePath: "/srv/second.txt",
                existingEntry: SFTPDirectoryEntry(
                    name: "second.txt",
                    kind: .file
                )
            ),
            PendingSFTPOverwrite.upload(
                transferID: UUID(),
                batchID: batchID,
                localURL: thirdURL,
                remotePath: "/srv/folder-name",
                existingEntry: SFTPDirectoryEntry(
                    name: "folder-name",
                    kind: .directory
                )
            ),
        ]

        for conflict in conflicts {
            let id = try XCTUnwrap(conflict.transferID)
            state.recordFileTransfer(
                FileTransferRecord(
                    id: id,
                    kind: .upload,
                    name: conflict.fileName,
                    sourcePath: root.path,
                    destinationPath: conflict.message,
                    status: .attention("already exists")
                )
            )
            model.enqueuePendingOverwrite(conflict, using: state)
        }

        XCTAssertEqual(model.pendingOverwrites.count, 3)
        XCTAssertEqual(model.pendingOverwriteSameTypeCount, 2)
        XCTAssertFalse(conflicts[2].canReplace)

        model.resolveOverwrite(
            .skip,
            applyToAll: true,
            using: state
        )

        XCTAssertEqual(model.pendingOverwrites.map(\.id), [conflicts[2].id])
        for conflict in conflicts.prefix(2) {
            let id = try XCTUnwrap(conflict.transferID)
            XCTAssertEqual(
                state.fileTransfers.first(where: { $0.id == id })?.status,
                .cancelled
            )
        }
        let remainingID = try XCTUnwrap(conflicts[2].transferID)
        XCTAssertEqual(
            state.fileTransfers.first(where: { $0.id == remainingID })?.status,
            .attention("already exists")
        )

        let lateConflict = PendingSFTPOverwrite.upload(
            transferID: UUID(),
            batchID: batchID,
            localURL: firstURL,
            remotePath: "/srv/late.txt",
            existingEntry: SFTPDirectoryEntry(
                name: "late.txt",
                kind: .file
            )
        )
        let lateID = try XCTUnwrap(lateConflict.transferID)
        state.recordFileTransfer(
            FileTransferRecord(
                id: lateID,
                kind: .upload,
                name: lateConflict.fileName,
                sourcePath: firstURL.path,
                destinationPath: "/srv/late.txt",
                status: .attention("already exists")
            )
        )
        model.enqueuePendingOverwrite(lateConflict, using: state)

        XCTAssertEqual(
            state.fileTransfers.first(where: { $0.id == lateID })?.status,
            .cancelled
        )
        XCTAssertEqual(model.pendingOverwrites.map(\.id), [conflicts[2].id])

        model.resolveOverwrite(.stop, using: state)

        XCTAssertTrue(model.pendingOverwrites.isEmpty)
        XCTAssertEqual(
            state.fileTransfers.first(where: { $0.id == remainingID })?.status,
            .cancelled
        )
    }
}
