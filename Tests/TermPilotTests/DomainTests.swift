import Foundation
import TermPilotDomain
import TermPilotTestSupport
import XCTest

final class DomainTests: XCTestCase {
    func testHostDistroDetectionMatchesOriginalNormalizationRules() {
        XCTAssertEqual(
            HostDistroID.detect(
                from: "NAME=\"Ubuntu\"\nID=ubuntu\nVERSION_ID=\"24.04\""
            ),
            .ubuntu
        )
        XCTAssertEqual(
            HostDistroID.detect(from: "ID=\"alinux\"\nNAME=\"Alibaba Cloud Linux\""),
            .alinux
        )
        XCTAssertEqual(
            HostDistroID.detect(from: "Darwin host 24.6.0 Darwin Kernel Version"),
            .macos
        )
        XCTAssertEqual(HostDistroID.normalize("Manjaro Linux"), .arch)
        XCTAssertNil(HostDistroID.normalize("Unknown Appliance"))
        XCTAssertEqual(
            HostDistroID.detectVendor(
                fromSSHVersion: "SSH-2.0-HUAWEI-VRP"
            ),
            .huawei
        )
        XCTAssertEqual(
            HostDistroID.detectVendor(fromSSHVersion: "FortiSSH_7.4"),
            .fortinet
        )
        XCTAssertNil(
            HostDistroID.detectVendor(
                fromSSHVersion: "SSH-2.0-OpenSSH_9.7"
            )
        )
    }

    func testHostAppearanceResolvesManualAndAutomaticColors() throws {
        var host = Fixtures.host()
        host.distro = .debian
        XCTAssertEqual(host.effectiveDistro, .debian)
        XCTAssertEqual(host.effectiveIconColorHex, "#A81D33")

        host.distroMode = .manual
        host.manualDistro = .ubuntu
        host.iconColorMode = .manual
        host.iconColorCustom = "#12ABEF"
        XCTAssertEqual(host.effectiveDistro, .ubuntu)
        XCTAssertEqual(host.effectiveIconColorHex, "#12ABEF")

        host.iconMode = .custom
        host.iconID = nil
        host.iconColorCustom = "invalid"
        let validated = try host.validated()
        XCTAssertEqual(validated.iconID, .server)
        XCTAssertNil(validated.iconColorCustom)
        XCTAssertEqual(validated.iconColor, .blue)
    }

    func testQuickConnectParsesDirectAndURLTargets() throws {
        XCTAssertEqual(
            try QuickConnectParser.parse("pilot@host.example.invalid:2222"),
            QuickConnectTarget(
                hostname: "host.example.invalid",
                username: "pilot",
                port: 2222
            )
        )
        XCTAssertEqual(
            try QuickConnectParser.parse("ssh://root@[2001:db8::1]:2200"),
            QuickConnectTarget(
                hostname: "2001:db8::1",
                username: "root",
                port: 2200
            )
        )
    }

    func testQuickConnectRejectsMissingUsernameAndBadPort() {
        XCTAssertThrowsError(try QuickConnectParser.parse("host.example.invalid")) {
            XCTAssertEqual($0 as? QuickConnectError, .missingUsername)
        }
        XCTAssertThrowsError(try QuickConnectParser.parse("pilot@host.example.invalid:70000")) {
            XCTAssertEqual($0 as? QuickConnectError, .invalidPort)
        }
    }

    func testWorkspaceInsertAndRemovePreservesOtherPanes() {
        let first = Fixtures.localSession()
        let second = Fixtures.localSession()
        let third = Fixtures.localSession()
        var root = WorkspaceNode.pane(id: UUID(), sessionID: first.id)
        XCTAssertEqual(root.paneCount, 1)

        root = root.inserting(
            sessionID: second.id,
            nextTo: first.id,
            axis: .vertical
        )
        XCTAssertEqual(root.paneCount, 2)
        root = root.inserting(
            sessionID: third.id,
            nextTo: second.id,
            axis: .horizontal
        )

        XCTAssertEqual(Set(root.sessionIDs), Set([first.id, second.id, third.id]))
        XCTAssertEqual(root.paneCount, 3)
        let pruned = root.removing(sessionID: second.id)
        XCTAssertEqual(Set(pruned?.sessionIDs ?? []), Set([first.id, third.id]))
        XCTAssertEqual(pruned?.paneCount, 2)
    }

    func testSnapshotPrunesUnknownSessionsAndNeverCarriesRuntimeState() throws {
        let valid = Fixtures.localSession()
        let missingID = UUID()
        let workspace = WorkspaceDocument(
            title: "Workspace",
            root: .split(
                id: UUID(),
                axis: .vertical,
                children: [
                    .pane(id: UUID(), sessionID: valid.id),
                    .pane(id: UUID(), sessionID: missingID),
                ],
                sizes: [0.8, 0.2]
            ),
            focusedSessionID: missingID
        )
        let snapshot = WorkspaceSnapshot(
            activeWorkspaceID: workspace.id,
            sessions: [valid],
            workspaces: [workspace]
        )

        let safe = try XCTUnwrap(snapshot.sanitized())
        XCTAssertEqual(safe.sessions, [valid])
        XCTAssertEqual(safe.workspaces[0].root.sessionIDs, [valid.id])
        XCTAssertEqual(safe.workspaces[0].focusedSessionID, valid.id)

        let payload = try JSONEncoder().encode(safe)
        let json = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(json.contains("scrollback"))
        XCTAssertFalse(json.contains("process"))
    }

    func testHostValidationRejectsUnsafeValues() {
        var host = Fixtures.host()
        host.port = 0
        XCTAssertThrowsError(try host.validated()) {
            XCTAssertEqual($0 as? HostValidationError, .invalidPort)
        }
    }

    func testProxyValidationNormalizesDirectAndCommandConfigurations() throws {
        let http = try SSHProxyConfiguration(
            type: .http,
            host: " proxy.example.invalid ",
            port: 3128,
            command: "stale",
            username: " proxy-user ",
            password: "fixture-proxy-value"
        ).validated()
        XCTAssertEqual(http.host, "proxy.example.invalid")
        XCTAssertEqual(http.username, "proxy-user")
        XCTAssertNil(http.command)

        let command = try SSHProxyConfiguration(
            type: .command,
            host: "stale",
            port: 8080,
            command: " cloudflared access ssh --hostname %h ",
            username: "stale",
            password: "stale"
        ).validated()
        XCTAssertEqual(command.command, "cloudflared access ssh --hostname %h")
        XCTAssertEqual(command.host, "")
        XCTAssertEqual(command.port, 0)
        XCTAssertNil(command.username)
        XCTAssertNil(command.password)
    }

    func testProxyValidationRejectsIncompleteEndpoint() {
        XCTAssertThrowsError(
            try SSHProxyConfiguration(
                type: .socks5,
                host: "",
                port: 1080
            ).validated()
        ) {
            XCTAssertEqual($0 as? SSHProxyValidationError, .invalidHost)
        }
        XCTAssertThrowsError(
            try SSHProxyConfiguration(
                type: .http,
                host: "proxy.example.invalid",
                port: 0
            ).validated()
        ) {
            XCTAssertEqual($0 as? SSHProxyValidationError, .invalidPort)
        }
    }

    func testElevationPasswordIsRetainedForSSHCredentials() throws {
        let keyCredential = try SSHCredential(
            label: "Production Key",
            username: "alice",
            kind: .identityKey,
            privateKey: "fixture-key-material",
            elevationPassword: "fixture-elevation-value"
        ).validated()
        XCTAssertEqual(keyCredential.elevationPassword, "fixture-elevation-value")

        let passwordCredential = try SSHCredential(
            label: "Production Password",
            username: "alice",
            kind: .password,
            password: "fixture-login-value",
            elevationPassword: "fixture-elevation-value"
        ).validated()
        XCTAssertEqual(passwordCredential.elevationPassword, "fixture-elevation-value")
    }

    func testSSHSessionDescriptorCarriesConnectionID() throws {
        let descriptor = SessionDescriptor.ssh(host: Fixtures.host())
        XCTAssertNotNil(descriptor.sshConnectionID)
    }

    func testSSHSessionDescriptorCarriesNonSecretHostFields() throws {
        let credentialID = UUID()
        var host = Fixtures.host()
        host.authentication = .identityFile
        host.credentialID = credentialID
        host.proxyProfileID = UUID()
        host.proxyConfiguration = SSHProxyConfiguration(
            type: .http,
            host: "proxy.example.invalid",
            port: 8080,
            password: "fixture-proxy-value"
        )
        host.identityFile = "/fixtures/identity/id_ed25519"
        host.identityKey = "fixture-key-content"
        host.passphrase = "fixture-passphrase-value"
        host.password = "fixture-login-value"
        host.sftpFileProtocol = .sftp
        host.sftpFilenameEncoding = .utf8
        host.sftpUsesSudo = true
        host.sftpFollowsTerminalCWD = true
        host.serverToolsUseRoot = true
        host.serverToolsElevationMethod = .su

        let descriptor = SessionDescriptor.ssh(host: host)

        XCTAssertEqual(descriptor.authentication, .identityFile)
        XCTAssertEqual(descriptor.credentialID, credentialID)
        XCTAssertEqual(descriptor.proxyProfileID, host.proxyProfileID)
        XCTAssertEqual(descriptor.customProxyConfigured, true)
        XCTAssertEqual(descriptor.identityFile, "/fixtures/identity/id_ed25519")
        XCTAssertEqual(descriptor.sftpFileProtocol, .sftp)
        XCTAssertEqual(descriptor.sftpFilenameEncoding, .utf8)
        XCTAssertEqual(descriptor.sftpUsesSudo, true)
        XCTAssertEqual(descriptor.sftpFollowsTerminalCWD, true)
        XCTAssertEqual(descriptor.serverToolsUseRoot, true)
        XCTAssertEqual(descriptor.serverToolsElevationMethod, .su)

        let payload = try JSONEncoder().encode(descriptor)
        let json = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertFalse(json.contains("fixture-key-content"))
        XCTAssertFalse(json.contains("fixture-passphrase-value"))
        XCTAssertFalse(json.contains("fixture-login-value"))
        XCTAssertFalse(json.contains("fixture-proxy-value"))
    }

    func testWorkspaceUpdatesNestedSplitSizesAndReplacesSessionIDs() {
        let first = UUID()
        let second = UUID()
        let splitID = UUID()
        let root = WorkspaceNode.split(
            id: splitID,
            axis: .vertical,
            children: [
                .pane(id: UUID(), sessionID: first),
                .pane(id: UUID(), sessionID: second),
            ],
            sizes: [0.5, 0.5]
        )

        let resized = root.updatingSplitSizes(
            splitID: splitID,
            sizes: [0.7, 0.3]
        )
        guard case let .split(_, _, _, sizes) = resized else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(sizes[0], 0.7, accuracy: 0.0001)

        let replacement = UUID()
        let copied = resized.replacingSessionIDs([first: replacement])
        XCTAssertEqual(Set(copied.sessionIDs), Set([replacement, second]))
        XCTAssertNotEqual(copied.id, resized.id)
    }

    func testWorkspaceCanAddSelectAndRemoveTerminalTabs() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let paneID = UUID()
        let root = WorkspaceNode.pane(id: paneID, sessionID: first)
            .addingTab(sessionID: second, nextTo: first)
            .addingTab(sessionID: third, nextTo: second)

        XCTAssertEqual(root.sessionIDs, [first, second, third])
        XCTAssertEqual(root.paneCount, 1)
        guard case let .tabGroup(_, _, activeAfterAdd) = root else {
            return XCTFail("Expected tab group")
        }
        XCTAssertEqual(activeAfterAdd, third)

        let selected = root.selectingTab(sessionID: second)
        guard case let .tabGroup(_, _, activeAfterSelect) = selected else {
            return XCTFail("Expected tab group")
        }
        XCTAssertEqual(activeAfterSelect, second)

        let removed = try XCTUnwrap(selected.removing(sessionID: second))
        guard case let .tabGroup(_, remaining, activeAfterRemove) = removed else {
            return XCTFail("Expected remaining tab group")
        }
        XCTAssertEqual(remaining, [first, third])
        XCTAssertEqual(activeAfterRemove, first)

        let collapsed = try XCTUnwrap(removed.removing(sessionID: first))
        guard case let .pane(_, remainingSessionID) = collapsed else {
            return XCTFail("Expected single remaining tab to collapse to pane")
        }
        XCTAssertEqual(remainingSessionID, third)
    }

    func testWorkspaceExtractingPaneKeepsTabGroupTogether() throws {
        let first = UUID()
        let second = UUID()
        let otherPane = UUID()
        let tabGroup = WorkspaceNode.pane(id: UUID(), sessionID: first)
            .addingTab(sessionID: second, nextTo: first)
        let root = tabGroup.inserting(
            sessionID: otherPane,
            nextTo: first,
            axis: .vertical
        )

        let extraction = root.extractingPane(containing: second)
        let remaining = try XCTUnwrap(extraction.remaining)
        let detached = try XCTUnwrap(extraction.detached)

        XCTAssertEqual(remaining.sessionIDs, [otherPane])
        XCTAssertEqual(detached.sessionIDs, [first, second])
        XCTAssertEqual(detached.paneCount, 1)
        guard case let .tabGroup(_, _, activeSessionID) = detached else {
            return XCTFail("Expected detached tab group")
        }
        XCTAssertEqual(activeSessionID, second)
    }

    func testWorkspaceCanInsertTabGroupAsPane() {
        let targetSessionID = UUID()
        let firstTabID = UUID()
        let secondTabID = UUID()
        let tabGroup = WorkspaceNode.tabGroup(
            id: UUID(),
            sessionIDs: [firstTabID, secondTabID],
            activeSessionID: secondTabID
        )
        let root = WorkspaceNode.pane(
            id: UUID(),
            sessionID: targetSessionID
        )

        let merged = root.insertingPane(
            tabGroup,
            nextTo: targetSessionID,
            axis: .horizontal,
            placement: .before
        )

        XCTAssertEqual(merged.paneCount, 2)
        guard case let .split(_, axis, children, _) = merged else {
            return XCTFail("Expected split workspace")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children[0], tabGroup)
        XCTAssertEqual(children[1].sessionIDs, [targetSessionID])
    }

    func testWorkspaceTerminalTabsCanMoveToRequestedIndex() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let root = WorkspaceNode.tabGroup(
            id: UUID(),
            sessionIDs: [first, second, third],
            activeSessionID: second
        )

        let moved = root.movingTab(sessionID: first, toIndex: 3)

        guard case let .tabGroup(_, sessionIDs, activeSessionID) = moved else {
            return XCTFail("Expected tab group")
        }
        XCTAssertEqual(sessionIDs, [second, third, first])
        XCTAssertEqual(activeSessionID, second)
    }

    func testWorkspaceCanSplitActiveTerminalTabIntoPane() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let root = WorkspaceNode.tabGroup(
            id: UUID(),
            sessionIDs: [first, second, third],
            activeSessionID: second
        )

        let split = root.splittingTab(
            sessionID: second,
            nextTo: second,
            axis: .horizontal,
            placement: .before
        )

        XCTAssertEqual(split.paneCount, 2)
        guard case let .split(_, axis, children, _) = split,
              case let .pane(_, splitSessionID) = children[0],
              case let .tabGroup(_, remainingIDs, activeSessionID) = children[1]
        else {
            return XCTFail("Expected split tab and remaining tab group")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(splitSessionID, second)
        XCTAssertEqual(remainingIDs, [first, third])
        XCTAssertEqual(activeSessionID, first)
    }
}
