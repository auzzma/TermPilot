import AppKit
import Foundation
import SwiftUI
@testable import TermPilotApp
import TermPilotDomain
import TermPilotPersistence
@testable import TermPilotScreenSharing
import XCTest

final class ScreenSharingTests: XCTestCase {
    func testCommandShortcutSynchronizesModifiersWithoutPriorFlagsChanged() {
        var keyboard = ScreenSharingKeyboardState()
        // Command may already be held when the remote view takes focus.
        XCTAssertEqual(keyboard.keyDown(code: 8, keysym: 0x63, flags: .command), [
            ScreenSharingKeyStroke(key: 0xffeb, down: true),
            ScreenSharingKeyStroke(key: 0x63, down: true)
        ])
        XCTAssertEqual(keyboard.keyUp(code: 8, flags: .command), [
            ScreenSharingKeyStroke(key: 0x63, down: false)
        ])
        // A key equivalent sends its own release; a later OS release is harmless.
        XCTAssertTrue(keyboard.keyUp(code: 8, flags: .command).isEmpty)
        XCTAssertEqual(keyboard.updateModifiers([]), [ScreenSharingKeyStroke(key: 0xffeb, down: false)])
    }

    func testModifierTransitionsAndFocusResetDoNotLeaveCommandPressed() {
        var keyboard = ScreenSharingKeyboardState()
        _ = keyboard.keyDown(code: 9, keysym: 0x76, flags: [.shift, .command])
        XCTAssertEqual(keyboard.keyUp(code: 9, flags: []), [
            ScreenSharingKeyStroke(key: 0x76, down: false),
            ScreenSharingKeyStroke(key: 0xffe1, down: false),
            ScreenSharingKeyStroke(key: 0xffeb, down: false)
        ])
        _ = keyboard.updateModifiers(.command)
        keyboard.reset()
        XCTAssertEqual(keyboard.updateModifiers(.command), [ScreenSharingKeyStroke(key: 0xffeb, down: true)])
    }

    func testEndpointValidationRejectsURLsAndInvalidPorts() {
        XCTAssertTrue(ScreenSharingEndpoint.isValid(host: "mac.local", port: 5900, username: "alice"))
        for host in ["", "vnc://mac.local", "a b", "mac.local/path"] {
            XCTAssertFalse(ScreenSharingEndpoint.isValid(host: host, port: 5900, username: "alice"))
        }
        for port in [0, -1, 65536] {
            XCTAssertFalse(ScreenSharingEndpoint.isValid(host: "mac.local", port: port, username: "alice"))
        }
    }

    func testScreenSharingCredentialIsEncryptedAndBackedUpIndependentlyFromSSH() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("vault.sqlite")
        let store = try VaultStore(databaseURL: db)
        let host = Host(label: "Test Mac", hostname: "mac.local", username: "ssh-user")
        try await store.saveHost(host)
        let profile = ScreenSharingProfile(hostID: host.id, username: "screen-user", password: "screen-secret-fixture", audio: false)
        try await store.saveScreenSharingProfile(profile)
        let restored = try await store.screenSharingProfile(hostID: host.id)
        XCTAssertEqual(restored, profile)
        let sshHost = try await store.fetchHost(id: host.id)
        XCTAssertEqual(sshHost?.username, "ssh-user")
        XCTAssertNil(sshHost?.password)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data("screen-secret-fixture".utf8)))
        }
        let snapshot = try await store.makeBackupSnapshot()
        XCTAssertEqual(snapshot.screenSharingProfiles, [profile])
        let destination = try VaultStore(databaseURL: directory.appendingPathComponent("other.sqlite"))
        let existingHost = Host(label: "Existing", hostname: "mac.local", username: "another-ssh-user")
        try await destination.saveHost(existingHost)
        _ = try await destination.importBackupSnapshot(snapshot)
        let imported = try await destination.screenSharingProfile(hostID: existingHost.id)
        XCTAssertEqual(imported?.username, "screen-user")
        XCTAssertEqual(imported?.password, profile.password)
        var forgotten = profile; forgotten.password = nil
        try await store.saveScreenSharingProfile(forgotten)
        let forgottenProfile = try await store.screenSharingProfile(hostID: host.id)
        XCTAssertNil(forgottenProfile?.password)
        try await store.deleteHost(id: host.id)
        let deleted = try await store.screenSharingProfile(hostID: host.id)
        XCTAssertNil(deleted)
    }

    func testWorkspaceDescriptorRoundTripDoesNotCarryPasswords() throws {
        var descriptor = SessionDescriptor(id: UUID(), kind: .screenSharing, title: "Mac",
            hostname: "mac.local", port: 5900, username: "alice")
        descriptor.screenSharingAudio = false
        let encoded = try JSONEncoder().encode(descriptor)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("password"))
        XCTAssertEqual(try JSONDecoder().decode(SessionDescriptor.self, from: encoded), descriptor)
        let old = SessionDescriptor.local(shell: "/bin/zsh")
        XCTAssertEqual(try JSONDecoder().decode(SessionDescriptor.self, from: JSONEncoder().encode(old)), old)
    }

    func testPacketParserHandlesSplitHeadersAndFrames() throws {
        let packet = try framePacket()
        var parser = ScreenSharingPacketDecoder()
        var result: [(ScreenSharingMessage, Data)] = []
        for byte in packet { result += try parser.append(Data([byte])) }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].0.kind, "frame")
        XCTAssertEqual(result[0].1, Data([128, 128, 128]))
        XCTAssertFalse(parser.hasIncompletePacket)
        result = try parser.append(packet + packet)
        XCTAssertEqual(result.count, 2)
    }

    func testPacketParserRejectsOversizedAndMalformedVideo() throws {
        var parser = ScreenSharingPacketDecoder()
        XCTAssertThrowsError(try parser.append(Data([0xff, 0xff, 0xff, 0xff])))
        var malformed = ScreenSharingPacketDecoder()
        XCTAssertThrowsError(try malformed.append(framePacket(width: 4000)))
        var truncated = ScreenSharingPacketDecoder()
        XCTAssertTrue(try truncated.append(Data(try framePacket().dropLast())).isEmpty)
        XCTAssertTrue(truncated.hasIncompletePacket)
    }

    func testPacketParserAccepts4K444BeyondOldPayloadLimit() throws {
        let width = 3840, height = 2160
        let payload = Data(repeating: 128, count: width * height * 3)
        let header: [String: Any] = ["kind":"frame", "payloadLength":payload.count, "tile":0,
            "width":width, "height":height, "chromaWidth":width, "chromaHeight":height,
            "yStride":width, "uvStride":width*2, "biplanar":true,
            "yLength":width*height, "uLength":width*height*2, "vLength":0]
        let json = try JSONSerialization.data(withJSONObject: header)
        var length = UInt32(json.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(json); packet.append(payload)
        var parser = ScreenSharingPacketDecoder()
        let frame = try XCTUnwrap(parser.append(packet).first)
        XCTAssertEqual(frame.0.width, width)
        XCTAssertEqual(frame.1.count, 24_883_200)
        var invalid = frame.0
        invalid.height = 2177
        XCTAssertThrowsError(try ScreenSharingFrame.validate(invalid, payload: payload))
    }

    func testMailboxKeepsOnlyLatestFrameForEachTile() throws {
        var parser = ScreenSharingPacketDecoder()
        let (header, data) = try XCTUnwrap(parser.append(framePacket()).first)
        let mailbox = ScreenSharingMailbox()
        for _ in 0..<100 { mailbox.put(ScreenSharingFrame(header: header, data: data)) }
        XCTAssertEqual(mailbox.takeFrames().count, 1)
        XCTAssertTrue(mailbox.takeFrames().isEmpty)
        for _ in 0..<100 { mailbox.putAudio(Data(count: 8000)) }
        XCTAssertLessThanOrEqual(mailbox.takeAudio().reduce(0) { $0 + $1.count }, 192_000)
    }

    func testPointerMappingHonorsLetterboxingAndDragClamping() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertNil(ScreenSharingGeometry.remotePoint(CGPoint(x: 500, y: 0), in: bounds))
        let center = try XCTUnwrap(ScreenSharingGeometry.remotePoint(CGPoint(x: 500, y: 500), in: bounds))
        XCTAssertEqual(center.x, 960, accuracy: 0.01)
        XCTAssertEqual(center.y, 540, accuracy: 0.01)
        let clamped = try XCTUnwrap(ScreenSharingGeometry.remotePoint(CGPoint(x: 1200, y: -30), in: bounds, clamp: true))
        XCTAssertEqual(clamped.x, 1919); XCTAssertEqual(clamped.y, 0)
    }

    @MainActor
    func testConnectionSheetFitsAndCanRenderOffscreen() throws {
        let view = NSHostingView(rootView: QuickConnectView(initialKind: .screenSharing)
            .environmentObject(AppState()).environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        let size = view.fittingSize
        XCTAssertLessThanOrEqual(size.width, 600)
        XCTAssertLessThanOrEqual(size.height, 800)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["TERMPILOT_SCREEN_SHARING_UI_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
    }

    @MainActor
    func testMetalPipelineCompilesOnThisMac() throws {
        let descriptor = SessionDescriptor(id: UUID(), kind: .screenSharing, title: "Renderer")
        let view = ScreenSharingMetalView(runtime: ScreenSharingSessionRuntime(descriptor: descriptor))
        XCTAssertTrue(view.isRendererReady)
    }

    @MainActor
    func testNativeRuntimeReadsFramesAndDisconnectsHelperWithoutStaleEvents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py")
        let modules = directory.appendingPathComponent("modules")
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("isharescreen"), withIntermediateDirectories: true)
        let bytes = try framePacket()
        let base64 = bytes.base64EncodedString()
        let source = """
        import sys,json,struct,base64
        config=json.loads(sys.stdin.buffer.readline())
        assert config['frameRate']==30
        def emit(obj,payload=b''):
            raw=json.dumps(dict(payloadLength=len(payload),**obj)).encode()
            sys.stdout.buffer.write(struct.pack('>I',len(raw))+raw+payload)
            sys.stdout.buffer.flush()
        emit(dict(kind='connected',width=config['width'],height=config['height'],decoder='fixture'))
        emit(dict(kind='clipboard'),b'unsolicited-text-must-be-ignored')
        sys.stdout.buffer.write(base64.b64decode('\(base64)'));sys.stdout.buffer.flush()
        for line in sys.stdin.buffer:
            command=json.loads(line); kind=command.get('kind')
            if kind=='disconnect': break
            if kind=='frameRate' and command['fps']==60: emit(dict(kind='status',stage='decode'))
            if kind=='clipboardSync' and command.get('enabled'): emit(dict(kind='clipboardChanged'))
            if kind=='clipboardFetch': emit(dict(kind='clipboard',requestID=command['requestID'],hasText=True),('中文 text\\n'*10000).encode())
        emit(dict(kind='disconnected'))
        """
        try ("#!/usr/bin/python3\n" + source).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let descriptor = SessionDescriptor(id: UUID(), kind: .screenSharing, title: "Fixture",
                                          hostname: "fixture.invalid", port: 5900, username: "test")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("local-fixture", forType: .string)
        let runtime = ScreenSharingSessionRuntime(descriptor: descriptor, pasteboard: pasteboard)
        runtime.setFrameRate(30)
        runtime.setClipboardFocused(true)
        runtime.connect(password: "fixture-password", launch: ScreenSharingEngineLaunch(
            executable: script, lockDirectory: directory))
        for _ in 0..<100 {
            if runtime.hasReceivedFrame { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(runtime.lifecycle, .connected)
        XCTAssertTrue(runtime.hasReceivedFrame)
        XCTAssertEqual(runtime.mailbox.takeFrames().count, 1)
        XCTAssertEqual(ScreenSharingMetalView(runtime: runtime).preferredFramesPerSecond, 30)
        runtime.setFrameRate(60)
        for _ in 0..<100 {
            if runtime.status == "Starting Video Decoder" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(runtime.status, "Starting Video Decoder")
        XCTAssertEqual(ScreenSharingMetalView(runtime: runtime).preferredFramesPerSecond, 60)
        XCTAssertEqual(pasteboard.string(forType: .string), "local-fixture")
        runtime.setClipboardSyncEnabled(true)
        // Toolbar focus changes release keys without discarding a valid reply.
        runtime.releaseInput()
        let expected = String(repeating: "中文 text\n", count: 10000)
        for _ in 0..<100 {
            if pasteboard.string(forType: .string) == expected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        for resolution in [HighPerformanceResolution.hd, .qhd, .uhd, .fullHD] {
            XCTAssertTrue(runtime.selectHighPerformanceResolution(resolution))
            XCTAssertFalse(runtime.selectHighPerformanceResolution(resolution))
            runtime.setFrameRate(30)
            runtime.connect(password: "fixture-password", launch: ScreenSharingEngineLaunch(executable: script, lockDirectory: directory))
            for _ in 0..<150 {
                if runtime.hasReceivedFrame { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(runtime.lifecycle, .connected)
            XCTAssertEqual(runtime.desktopSize, CGSize(width: resolution.width, height: resolution.height))
            let point = try XCTUnwrap(ScreenSharingGeometry.remotePoint(CGPoint(x: 2000, y: 2000),
                in: CGRect(x: 0, y: 0, width: 1000, height: 800), remoteSize: runtime.desktopSize, clamp: true))
            XCTAssertEqual(point.x, CGFloat(resolution.width - 1))
            XCTAssertEqual(point.y, CGFloat(resolution.height - 1))
            XCTAssertEqual(runtime.disconnectedCopy(for: descriptor).highPerformanceResolution, resolution)
        }
        runtime.disconnect()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(runtime.lifecycle, .disconnected)
        XCTAssertFalse(runtime.hasReceivedFrame)
    }

    @MainActor
    func testPasteKeysFollowClipboardAcknowledgementAndAreCancelledOnFocusLoss() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("paste-fixture.py")
        let log = directory.appendingPathComponent("commands.jsonl")
        let modules = directory.appendingPathComponent("modules")
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("isharescreen"), withIntermediateDirectories: true)
        let source = """
        import sys,json,struct,time,pathlib
        config=json.loads(sys.stdin.buffer.readline())
        log=open(pathlib.Path(__file__).with_name('commands.jsonl'),'w',buffering=1)
        def record(value): log.write(json.dumps(value)+'\\n')
        def emit(obj,payload=b''):
            raw=json.dumps(dict(payloadLength=len(payload),**obj)).encode()
            sys.stdout.buffer.write(struct.pack('>I',len(raw))+raw+payload);sys.stdout.buffer.flush()
        emit(dict(kind='connected',decoder='fixture'))
        text=''
        for line in sys.stdin.buffer:
            command=json.loads(line);record(command)
            kind=command.get('kind')
            if kind=='disconnect': break
            if kind=='clipboardSend': text=command['text']
            if kind=='clipboardFetch':
                time.sleep(0.15)
                record(dict(kind='readbackComplete'))
                emit(dict(kind='clipboard',requestID=command['requestID'],hasText=True),text.encode())
        """
        try ("#!/usr/bin/python3\n" + source).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let runtime = ScreenSharingSessionRuntime(descriptor: SessionDescriptor(id: UUID(), kind: .screenSharing,
            title: "Fixture", hostname: "fixture.invalid", port: 5900, username: "test"), pasteboard: board)
        runtime.setClipboardSyncEnabled(true)
        runtime.setClipboardFocused(true)
        runtime.connect(password: "fixture-password", launch: ScreenSharingEngineLaunch(
            executable: script, lockDirectory: directory))
        defer { runtime.disconnect() }
        for _ in 0..<100 {
            if runtime.lifecycle == .connected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(runtime.lifecycle, .connected)
        func events() -> [[String: Any]] {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            } ?? []
        }
        func pasteShortcut() {
            runtime.sendKey(0xffeb, down: true)
            runtime.sendKey(0x76, down: true)
            runtime.sendKey(0x76, down: false)
            runtime.sendKey(0xffeb, down: false)
        }
        board.clearContents(); board.setString("fixture paste", forType: .string)
        pasteShortcut()
        for _ in 0..<100 {
            if events().contains(where: { $0["key"] as? Int == 0x76 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sent = events()
        let ack = try XCTUnwrap(sent.firstIndex(where: { $0["kind"] as? String == "readbackComplete" }))
        let paste = try XCTUnwrap(sent.firstIndex(where: { $0["key"] as? Int == 0x76 }))
        XCTAssertGreaterThan(paste, ack)
        XCTAssertEqual(sent.filter { $0["key"] as? Int == 0x76 }.count, 2)
        board.clearContents(); board.setString("cancelled fixture paste", forType: .string)
        pasteShortcut()
        runtime.sendPointer(x: 100, y: 100, buttons: 1)
        runtime.sendPointer(x: 100, y: 100, buttons: 0)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(events().filter { $0["key"] as? Int == 0x76 }.count, 2)
        board.clearContents(); board.setString("cancel on blur", forType: .string)
        pasteShortcut()
        runtime.setClipboardFocused(false)
        runtime.releaseInput()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(events().filter { $0["key"] as? Int == 0x76 }.count, 2)
    }

    @MainActor
    func testScreenSharingTabCanBeDuplicatedSplitAndClosedAlongsideTerminal() async throws {
        let state = AppState()
        // Create a disconnected tab without starting a network connection.
        state.prepareScreenSharing()
        XCTAssertTrue(state.showingScreenSharing)
        await state.addScreenSharingSession(SessionDescriptor(id: UUID(), kind: .screenSharing,
            title: "Fixture", hostname: "fixture.invalid", port: 5900, username: "test"), splitAxis: nil)
        let workspace = try XCTUnwrap(state.activeWorkspace)
        state.screenSharingRuntimes[workspace.focusedSessionID]?.disconnect()
        await state.duplicateWorkspace(id: workspace.id)
        XCTAssertEqual(state.screenSharingRuntimes.count, 2)
        let copy = try XCTUnwrap(state.activeWorkspace)
        XCTAssertEqual(state.screenSharingRuntimes[copy.focusedSessionID]?.lifecycle, .disconnected)
        let tabID = await state.openTerminalTab(from: workspace.focusedSessionID, in: workspace.id)
        XCTAssertEqual(state.activeWorkspaceID, workspace.id)
        await state.close(sessionID: try XCTUnwrap(tabID), in: workspace.id)
        state.activeWorkspaceID = copy.id
        await state.openLocalShell(splitAxis: .vertical)
        XCTAssertEqual(state.activeWorkspace?.root.paneCount, 2)
        let snapshot = try XCTUnwrap(state.currentWorkspaceSnapshot())
        XCTAssertEqual(snapshot.sessions.filter { $0.kind == .screenSharing }.count, 2)
        XCTAssertEqual(snapshot.sessions.filter { $0.kind == .local }.count, 1)
        let clone = try XCTUnwrap(state.currentWorkspaceCloneSnapshot())
        XCTAssertEqual(clone.sessions.count, 3)
        XCTAssertTrue(Set(clone.sessions.map(\.id)).isDisjoint(with: snapshot.sessions.map(\.id)))
        await state.closeWorkspace(copy.id)
        XCTAssertEqual(state.screenSharingRuntimes.count, 1)
        await state.closeWorkspace(workspace.id)
        XCTAssertTrue(state.screenSharingRuntimes.isEmpty)
        XCTAssertTrue(state.sessions.isEmpty)
    }

    /// The helper checks the credential passed on stdin, then either stays connected or
    /// immediately rejects the attempt and exits. Only test fixture values reach it.
    private func reconnectFixture(in directory: URL) throws -> ScreenSharingEngineLaunch {
        let helper = directory.appendingPathComponent("desktop-fixture")
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, struct, sys
        def emit(**event):
            packet = json.dumps(dict(payloadLength=0, **event)).encode()
            sys.stdout.buffer.write(struct.pack(">I", len(packet)) + packet)
            sys.stdout.buffer.flush()
        cfg = json.loads(sys.stdin.buffer.readline())
        expected = pathlib.Path(__file__).with_name("expected").read_text()
        emit(kind="status", stage="authenticate")
        if cfg["password"] != expected:
            emit(kind="error", code="authenticationRejected")
            emit(kind="disconnected")
            sys.exit(1)
        emit(kind="connected", width=2, height=2)
        for line in sys.stdin:
            if json.loads(line).get("kind") == "disconnect": break
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return ScreenSharingEngineLaunch(executable: helper, lockDirectory: directory)
    }

    @MainActor
    private func waitForScreenState(_ runtime: ScreenSharingSessionRuntime, _ expected: SessionLifecycle) async throws {
        let deadline = Date().addingTimeInterval(8)
        while runtime.lifecycle != expected && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(runtime.lifecycle, expected)
    }

    @MainActor
    func testReconnectPaneHasNoCredentialEditorAfterDisconnectOrFailure() throws {
        let state = AppState()
        let runtime = ScreenSharingSessionRuntime(descriptor: SessionDescriptor(kind: .screenSharing,
            title: "Screen Sharing", hostname: "example.invalid", username: "fixture"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: .borderless,
                              backing: .buffered, defer: false)
        let view = NSHostingView(rootView: ScreenSharingPane(runtime: runtime, workspaceID: UUID(), isActive: false)
            .environmentObject(state))
        window.contentView = view
        func containsPasswordEditor(_ view: NSView) -> Bool {
            view is NSSecureTextField || view.subviews.contains(where: containsPasswordEditor)
        }
        for failure in [false, true] {
            if failure { runtime.connectionFailed("The remote Mac rejected authentication. Check the account and password.") }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertFalse(containsPasswordEditor(view))
        }
    }

    @MainActor
    func testQuickScreenReconnectReusesOnlyThisSessionsCredentialAndNeverSerializesIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = try reconnectFixture(in: directory)
        let state = AppState(vaultStore: try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite")), screenSharingLaunch: launch)
        let expected = directory.appendingPathComponent("expected")
        let secret = "test-quick-screen-password"
        try secret.write(to: expected, atomically: true, encoding: .utf8)
        let opened = await state.openScreenSharing(hostname: "loopback.invalid", port: 5900, username: "fixture",
            password: secret, audio: false, host: nil)
        XCTAssertTrue(opened)
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let runtime = try XCTUnwrap(state.screenSharingRuntimes[workspace.focusedSessionID])
        try await waitForScreenState(runtime, .connected)
        state.disconnectScreenSharing(sessionID: runtime.descriptor.id)
        state.reconnect(sessionID: runtime.descriptor.id)
        state.disconnectScreenSharing(sessionID: runtime.descriptor.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtime.lifecycle, .disconnected)
        state.reconnect(sessionID: runtime.descriptor.id)
        try await waitForScreenState(runtime, .connected)

        try "server-now-expects-a-different-password".write(to: expected, atomically: true, encoding: .utf8)
        runtime.disconnect()
        state.reconnect(sessionID: runtime.descriptor.id)
        try await waitForScreenState(runtime, .failed("The remote Mac rejected authentication. Check the account and password."))
        XCTAssertFalse(runtime.connectionDiagnostics.contains(secret))
        let snapshot = try XCTUnwrap(state.currentWorkspaceSnapshot())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(secret))
        try secret.write(to: expected, atomically: true, encoding: .utf8)
        let sibling = await state.openTerminalTab(from: runtime.descriptor.id, in: workspace.id)
        let copy = try XCTUnwrap(sibling.flatMap { state.screenSharingRuntimes[$0] })
        state.reconnect(sessionID: copy.descriptor.id)
        try await waitForScreenState(copy, .connected)
        await state.closeWorkspace(workspace.id)

        let restored = ScreenSharingSessionRuntime(descriptor: runtime.descriptor)
        restored.connect(password: nil, launch: launch, proxyConfiguration: nil)
        XCTAssertEqual(restored.lifecycle, .failed("No desktop credential is available. Update the saved host or open Quick Connect again."))
    }

    @MainActor
    func testQuickScreenReconnectRefreshesSelectedPasswordCredential() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = try reconnectFixture(in: directory)
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let state = AppState(vaultStore: store, screenSharingLaunch: launch)
        var credential = SSHCredential(label: "Fixture", username: "fixture", kind: .password, password: "first")
        try await store.saveCredential(credential)
        await state.refreshCredentials()
        let expected = directory.appendingPathComponent("expected")
        try "first".write(to: expected, atomically: true, encoding: .utf8)
        _ = await state.openScreenSharing(hostname: "desktop.invalid", port: 5900, username: "fixture", password: "first",
            audio: false, host: nil, credentialID: credential.id)
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let runtime = try XCTUnwrap(state.screenSharingRuntimes[workspace.focusedSessionID])
        try await waitForScreenState(runtime, .connected)
        credential.password = "updated"
        try await store.saveCredential(credential)
        await state.refreshCredentials()
        try "updated".write(to: expected, atomically: true, encoding: .utf8)
        state.reconnect(sessionID: runtime.descriptor.id)
        try await waitForScreenState(runtime, .connected)
        await state.closeWorkspace(workspace.id)
    }

    @MainActor
    func testSavedScreenReconnectReadsCorrectedVaultPasswordAndRejectsAnEndpointChange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = try reconnectFixture(in: directory)
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let state = AppState(vaultStore: store, screenSharingLaunch: launch)
        var host = Host(label: "Saved desktop", hostname: "screen.invalid", connectionKind: .screenSharing, username: "fixture", authentication: .password)
        var profile = ScreenSharingProfile(hostID: host.id, username: "fixture", password: "old-test-password", audio: false)
        try await store.saveHost(host, screenSharingProfile: profile)
        try "corrected-test-password".write(to: directory.appendingPathComponent("expected"), atomically: true, encoding: .utf8)
        await state.connect(host: host)
        let workspace = try XCTUnwrap(state.activeWorkspace)
        let runtime = try XCTUnwrap(state.screenSharingRuntimes[workspace.focusedSessionID])
        try await waitForScreenState(runtime, .failed("The remote Mac rejected authentication. Check the account and password."))
        profile.password = "corrected-test-password"
        try await store.saveScreenSharingProfile(profile)
        state.reconnect(sessionID: runtime.descriptor.id)
        try await waitForScreenState(runtime, .connected)

        // A linked password credential takes precedence over the profile password.
        let credential = SSHCredential(label: "Desktop credential", username: "fixture", kind: .password, password: "linked-password")
        try await store.saveCredential(credential)
        host.credentialID = credential.id
        try await store.saveHost(host, screenSharingProfile: profile)
        await state.refreshCredentials()
        try "linked-password".write(to: directory.appendingPathComponent("expected"), atomically: true, encoding: .utf8)
        runtime.disconnect()
        state.reconnect(sessionID: runtime.descriptor.id)
        try await waitForScreenState(runtime, .connected)
        host.hostname = "another.invalid"
        try await store.saveHost(host, screenSharingProfile: profile)
        state.reconnect(sessionID: runtime.descriptor.id)
        try await waitForScreenState(runtime, .failed(AppLocalization.errorDescription(ScreenSharingConfigurationError.savedConnectionChanged)))
        await state.closeWorkspace(workspace.id)
    }

    @MainActor
    func testConnectionFailurePreservesActionableDiagnosticAfterHelperExits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("failure.py")
        let modules = directory.appendingPathComponent("modules")
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("isharescreen"), withIntermediateDirectories: true)
        try """
        import sys,json,struct
        sys.stdin.buffer.readline()
        for event in [dict(kind='status',stage='udpBind'),dict(kind='error',stage='udpBind',code='udpPortsInUse')]:
            raw=json.dumps(dict(payloadLength=0,**event)).encode()
            sys.stdout.buffer.write(struct.pack('>I',len(raw))+raw)
        sys.stdout.buffer.flush()
        sys.exit(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        let fixtureSource = try String(contentsOf: script, encoding: .utf8)
        try ("#!/usr/bin/python3\n" + fixtureSource).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let descriptor = SessionDescriptor(id: UUID(), kind: .screenSharing, title: "Fixture",
            hostname: "fixture.invalid", port: 5900, username: "test")
        let runtime = ScreenSharingSessionRuntime(descriptor: descriptor)
        runtime.connect(password: "fixture-password", launch: ScreenSharingEngineLaunch(
            executable: script, lockDirectory: directory))
        // Process startup varies under concurrent native release builds. Await
        // the actual failure event instead of assuming the helper starts in 1 s.
        let deadline = Date().addingTimeInterval(10)
        while runtime.isActive && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runtime.lifecycle, .failed("UDP media ports are in use. Disconnect the system Screen Sharing session or another remote desktop viewer, then retry."))
        XCTAssertEqual(runtime.connectionDiagnostics, "stage=udpBind; code=udpPortsInUse")
        XCTAssertFalse(runtime.isActive)
    }

    func testStandardVNCModeSupportsOnlyTCPProxyTypes() throws {
        for type in [SSHProxyType.http, .socks5] {
            let proxy = SSHProxyConfiguration(type: type, host: "localhost", port: 1080)
            XCTAssertNoThrow(try ScreenSharingEndpoint.validateProxy(profileID: UUID(), configuration: proxy, mode: .standardVNC))
            XCTAssertThrowsError(try ScreenSharingEndpoint.validateProxy(profileID: nil, configuration: proxy))
        }
        XCTAssertThrowsError(try ScreenSharingEndpoint.validateProxy(profileID: nil,
            configuration: SSHProxyConfiguration(type: .command, command: "fixture"), mode: .standardVNC))
        XCTAssertTrue(ScreenSharingEndpoint.isValid(host: "vnc.example.invalid", port: 5900, username: "", mode: .standardVNC))
        XCTAssertFalse(ScreenSharingEndpoint.isValid(host: "vnc.example.invalid", port: 5900, username: ""))
    }

    func testStandardVNCModePersistsAndLegacyProfileKeepsHighPerformance() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let host = TermPilotDomain.Host(label: "VNC", hostname: "vnc.example.invalid", connectionKind: .screenSharing, username: "")
        let profile = ScreenSharingProfile(hostID: host.id, username: "", password: "fixture", audio: false, mode: .standardVNC)
        try await store.saveHost(host, screenSharingProfile: profile)
        let restored = try await store.screenSharingProfile(hostID: host.id)
        XCTAssertEqual(restored, profile)
        let old = "{\"hostID\":\"\(host.id.uuidString)\",\"port\":5900,\"username\":\"mac\",\"audio\":true}"
        let legacy = try JSONDecoder().decode(ScreenSharingProfile.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.effectiveMode, .highPerformance)
        var descriptor = SessionDescriptor(kind: .screenSharing, title: "VNC", hostname: host.hostname, port: 5900)
        descriptor.screenSharingMode = .standardVNC
        descriptor.proxyProfileID = UUID()
        let encoded = try JSONEncoder().encode(descriptor)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture"))
        XCTAssertEqual(try JSONDecoder().decode(SessionDescriptor.self, from: encoded), descriptor)
    }

    func testStandardVNCFramePacketAcceptsRGBAndRejectsInvalidSizes() throws {
        func packet(width: Int, stride: Int) throws -> Data {
            let header = try JSONSerialization.data(withJSONObject: ["kind":"frame", "payloadLength":8,
                "tile":0, "width":width, "height":1, "yStride":stride, "pixelFormat":"bgrx"])
            var length = UInt32(header.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + header + Data(repeating: 128, count: 8)
        }
        var parser = ScreenSharingPacketDecoder()
        let output = try parser.append(packet(width: 2, stride: 8))
        XCTAssertEqual(output.first?.0.pixelFormat, "bgrx")
        XCTAssertEqual(output.first?.1.count, 8)
        for (width, stride) in [(3,12),(2,4),(8193,32772)] {
            var invalid = ScreenSharingPacketDecoder()
            XCTAssertThrowsError(try invalid.append(packet(width: width, stride: stride)))
        }
    }

    func testStandardVNCPointerUsesActualDesktopDimensions() throws {
        let desktop = CGSize(width: 1280, height: 1024)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let point = try XCTUnwrap(ScreenSharingGeometry.remotePoint(CGPoint(x: 500, y: 500), in: bounds, remoteSize: desktop))
        XCTAssertEqual(point.x, 640, accuracy: 0.01)
        XCTAssertEqual(point.y, 512, accuracy: 0.01)
        let clamped = try XCTUnwrap(ScreenSharingGeometry.remotePoint(CGPoint(x: 2000, y: 2000), in: bounds, remoteSize: desktop, clamp: true))
        XCTAssertEqual(clamped.x, 1279); XCTAssertEqual(clamped.y, 1023)
    }

    @MainActor
    func testStandardVNCMissingProxyCannotStartDirectHelper() {
        var descriptor = SessionDescriptor(kind: .screenSharing, title: "VNC", hostname: "fixture.invalid", port: 5900)
        descriptor.screenSharingMode = .standardVNC
        descriptor.customProxyConfigured = true
        let runtime = ScreenSharingSessionRuntime(descriptor: descriptor)
        let absent = URL(fileURLWithPath: "/fixture-missing")
        runtime.connect(password: "fixture", launch: ScreenSharingEngineLaunch(executable: absent, lockDirectory: absent))
        XCTAssertEqual(runtime.lifecycle, .failed("The proxy configuration is unavailable. Reopen Quick Connect and select the proxy again."))
        XCTAssertFalse(runtime.supportsFileTransfer)
        XCTAssertFalse(runtime.audioEnabled)
    }

    @MainActor
    func testStandardVNCHelperReceivesProxyOverPrivatePipeAndRendersRGB() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py")
        let modules = directory.appendingPathComponent("modules")
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("isharescreen"), withIntermediateDirectories: true)
        try """
        import sys,json,struct
        cfg=json.loads(sys.stdin.buffer.readline())
        assert cfg['mode']=='standardVNC'
        assert cfg['proxy']['type']=='socks5'
        assert cfg['proxy']['password']=='fixture-proxy-secret'
        assert cfg['password']=='fixture-login'
        def emit(kind,payload=b'',**kw):
            header=json.dumps(dict(kind=kind,payloadLength=len(payload),**kw)).encode()
            sys.stdout.buffer.write(struct.pack('>I',len(header))+header+payload)
            sys.stdout.buffer.flush()
        emit('connected',width=2,height=1,decoder='fixture-vnc')
        emit('frame',bytes(8),tile=0,width=2,height=1,yStride=8,pixelFormat='bgrx')
        for line in sys.stdin.buffer:
            if json.loads(line).get('kind')=='disconnect': break
        """.write(to: script, atomically: true, encoding: .utf8)
        let fixtureSource = try String(contentsOf: script, encoding: .utf8)
        try ("#!/usr/bin/python3\n" + fixtureSource).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var descriptor = SessionDescriptor(kind: .screenSharing, title: "VNC", hostname: "fixture.invalid", port: 5900)
        descriptor.screenSharingMode = .standardVNC
        descriptor.customProxyConfigured = true
        let runtime = ScreenSharingSessionRuntime(descriptor: descriptor,
            proxyConfiguration: SSHProxyConfiguration(type: .socks5, host: "proxy.invalid", port: 1080,
                username: "proxy-user", password: "fixture-proxy-secret"))
        runtime.connect(password: "fixture-login", launch: ScreenSharingEngineLaunch(
            executable: script, lockDirectory: directory))
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(runtime.lifecycle, .connected)
        XCTAssertTrue(runtime.hasReceivedFrame)
        XCTAssertEqual(runtime.desktopSize, CGSize(width: 2, height: 1))
        let view = ScreenSharingMetalView(runtime: runtime)
        XCTAssertTrue(view.isRendererReady)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.draw(in: view)
        runtime.disconnect()
    }

    private func framePacket(width: Int = 1) throws -> Data {
        let header: [String: Any] = ["kind": "frame", "payloadLength": 3, "tile": 0,
            "width": width, "height": 1, "yStride": 1, "uvStride": 1,
            "chromaWidth": 1, "chromaHeight": 1, "biplanar": false,
            "yLength": 1, "uLength": 1, "vLength": 1]
        let encoded = try JSONSerialization.data(withJSONObject: header)
        let length = UInt32(encoded.count)
        return Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
            + encoded + Data([128, 128, 128])
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-sharing-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
