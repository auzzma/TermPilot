import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TermPilotApp
import TermPilotDomain
import TermPilotPersistence
@testable import TermPilotScreenSharing

@MainActor
final class ScreenSharingLoginInputTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testAcknowledgedUnicodeInputEndsWithOneReturnAndNeverUsesClipboard() async throws {
        let input = ScreenSharingLoginInput()
        input.isAvailable = { true }
        var commands = [[String: Any]]()
        input.send = { commands.append($0); return true }
        let operation = try XCTUnwrap(input.begin())
        let password = "Ab!\"'\\ 空🔑é"
        let task = Task { await input.perform(password: password, operation: operation) }
        try await waitUntil { commands.count == 1 }
        XCTAssertNil(input.begin())
        input.acknowledge("wrong-attempt")
        await Task.yield()
        XCTAssertEqual(commands.count, 1)
        let expected = password.unicodeScalars.map { $0.value <= 0xff ? $0.value : $0.value | 0x01000000 } + [UInt32(0xff0d)]
        for (index, key) in expected.enumerated() {
            try await waitUntil { commands.filter { $0["kind"] as? String == "credentialKey" }.count > index }
            let command = commands.filter { $0["kind"] as? String == "credentialKey" }[index]
            XCTAssertEqual(command["key"] as? UInt32, key)
            input.acknowledge(try XCTUnwrap(command["requestID"] as? String))
        }
        await task.value
        XCTAssertFalse(input.isRunning)
        XCTAssertEqual(input.message, "Password and Return sent. Check the remote login result.")
        XCTAssertFalse(input.message.contains(password))
        XCTAssertTrue(commands.allSatisfy { ["credentialKey", "release"].contains($0["kind"] as? String) })
    }

    func testCancellationDropsRemainingCharactersAndStaleAcknowledgements() async throws {
        let input = ScreenSharingLoginInput()
        input.isAvailable = { true }
        var commands = [[String: Any]]()
        input.send = { commands.append($0); return true }
        let operation = try XCTUnwrap(input.begin())
        let task = Task { await input.perform(password: "fixture-long-password", operation: operation) }
        try await waitUntil { !commands.isEmpty }
        let stale = try XCTUnwrap(commands[0]["requestID"] as? String)
        input.cancel(); await task.value
        XCTAssertEqual(commands.filter { $0["kind"] as? String == "credentialKey" }.count, 1)
        let next = try XCTUnwrap(input.begin())
        let nextTask = Task { await input.perform(password: "next", operation: next) }
        try await waitUntil { commands.filter { $0["kind"] as? String == "credentialKey" }.count == 2 }
        input.acknowledge(stale)
        await Task.yield()
        XCTAssertEqual(commands.filter { $0["kind"] as? String == "credentialKey" }.count, 2)
        input.cancel(); await nextTask.value
        XCTAssertFalse(commands.contains { $0["key"] as? UInt32 == 0xff0d })
    }

    func testTimeoutAndInvalidPasswordsNeverSubmit() async throws {
        let input = ScreenSharingLoginInput()
        input.isAvailable = { true }; input.timeout = .milliseconds(40)
        var keys = [UInt32]()
        input.send = { if let key = $0["key"] as? UInt32 { keys.append(key) }; return true }
        for password in [nil, "", "bad\npassword", "\t", String(repeating: "x", count: 1025)] as [String?] {
            let operation = try XCTUnwrap(input.begin())
            await input.perform(password: password, operation: operation)
            XCTAssertTrue(keys.isEmpty)
            XCTAssertFalse(input.isRunning)
        }
        let operation = try XCTUnwrap(input.begin())
        await input.perform(password: "timeout", operation: operation)
        XCTAssertEqual(keys, [UInt32(Character("t").asciiValue!)])
        XCTAssertEqual(input.message, "Credential password input timed out. Check the remote field before retrying.")
    }

    private func fixture() throws -> (URL, ScreenSharingEngineLaunch) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-login-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("desktop-fixture")
        try #"""
        #!/usr/bin/python3
        import json, pathlib, struct, sys
        root = pathlib.Path(__file__).parent
        def emit(payload=b'', **event):
            packet = json.dumps(dict(payloadLength=len(payload), **event)).encode()
            sys.stdout.buffer.write(struct.pack('>I', len(packet)) + packet + payload)
            sys.stdout.buffer.flush()
        cfg = json.loads(sys.stdin.buffer.readline())
        emit(kind='connected', width=2, height=2)
        emit(kind='frame', tile=0, width=2, height=2, yStride=8, pixelFormat='bgrx', payload=bytes(16))
        with (root/'commands.jsonl').open('a',buffering=1) as log:
            for line in sys.stdin:
                command=json.loads(line)
                if command['kind']=='disconnect': break
                log.write(json.dumps(command)+'\n')
                if command['kind']=='credentialKey' and not (root/'pause').exists():
                    emit(kind='credentialKeySent', requestID=command['requestID'])
        """#.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return (directory, ScreenSharingEngineLaunch(executable: helper, lockDirectory: directory))
    }
    private func enteredKeys(_ directory: URL) -> [UInt32] {
        (try? String(contentsOf: directory.appendingPathComponent("commands.jsonl"), encoding: .utf8))?
            .split(separator: "\n").compactMap { line in
                guard let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      item["kind"] as? String == "credentialKey" else { return nil }
                return (item["key"] as? NSNumber)?.uint32Value
            } ?? []
    }
    private func expectedKeys(_ password: String) -> [UInt32] {
        password.unicodeScalars.map { $0.value <= 0xff ? $0.value : $0.value | 0x01000000 } + [0xff0d]
    }

    func testSavedHostLoginReadsUpdatedCredentialWithoutReconnectAndGuardsAccount() async throws {
        let (directory, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let state = AppState(vaultStore: store, screenSharingLaunch: launch)
        var host = Host(label: "Login fixture", hostname: "fixture.invalid", connectionKind: .screenSharing, username: "fixture", authentication: .password)
        var profile = ScreenSharingProfile(hostID: host.id, username: "fixture", password: "first", audio: false)
        try await store.saveHost(host); try await store.saveScreenSharingProfile(profile)
        await state.connect(host: host)
        let runtime = try XCTUnwrap(state.screenSharingRuntimes.values.first)
        defer { runtime.disconnect() }
        try await waitUntil { runtime.canSendLoginPassword }
        profile.password = "corrected!"
        try await store.saveScreenSharingProfile(profile)
        await state.enterScreenSharingLoginPassword(sessionID: runtime.descriptor.id)
        XCTAssertEqual(enteredKeys(directory), expectedKeys("corrected!"))
        var credential = SSHCredential(label: "Login reference", username: "fixture", kind: .password, password: "linked")
        try await store.saveCredential(credential)
        host.credentialID = credential.id; try await store.saveHost(host)
        credential.password = "latest#"; try await store.saveCredential(credential)
        await state.enterScreenSharingLoginPassword(sessionID: runtime.descriptor.id)
        XCTAssertEqual(enteredKeys(directory), expectedKeys("corrected!") + expectedKeys("latest#"))
        let count = enteredKeys(directory).count
        host.hostname = "different.invalid"; try await store.saveHost(host)
        await state.enterScreenSharingLoginPassword(sessionID: runtime.descriptor.id)
        XCTAssertEqual(enteredKeys(directory).count, count)
        XCTAssertEqual(runtime.lifecycle, .connected)
        XCTAssertFalse(runtime.isEnteringLoginPassword)
        XCTAssertTrue(runtime.loginPasswordStatus.contains("changed") || runtime.loginPasswordStatus.contains("更改"))
    }

    func testQuickPasswordAndCredentialReferenceReuseAndVisibilityCancellation() async throws {
        let (directory, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let state = AppState(vaultStore: store, screenSharingLaunch: launch)
        let password = "Quick!空"
        _ = await state.openScreenSharing(hostname: "fixture.invalid", port: 5900, username: "fixture", password: password, audio: false, host: nil)
        let runtime = try XCTUnwrap(state.screenSharingRuntimes.values.first)
        defer { runtime.disconnect() }
        try await waitUntil { runtime.canSendLoginPassword }
        await state.enterScreenSharingLoginPassword(sessionID: runtime.descriptor.id)
        XCTAssertEqual(enteredKeys(directory), expectedKeys(password))
        let snapshot = try XCTUnwrap(state.currentWorkspaceSnapshot())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(password))
        try Data().write(to: directory.appendingPathComponent("pause"))
        let count = enteredKeys(directory).count
        let pending = Task { await state.enterScreenSharingLoginPassword(sessionID: runtime.descriptor.id) }
        try await waitUntil { self.enteredKeys(directory).count > count }
        runtime.sendPointer(x: 40, y: 50, buttons: 1)
        runtime.sendKey(0x62, down: true)
        runtime.setVisible(false)
        await pending.value
        XCTAssertEqual(enteredKeys(directory).count, count + 1)
        XCTAssertFalse(runtime.isEnteringLoginPassword)
        XCTAssertNil(runtime.beginLoginPasswordInput())
        try FileManager.default.removeItem(at: directory.appendingPathComponent("pause"))
        var credential = SSHCredential(label: "Quick reference", username: "fixture", kind: .password, password: "old")
        try await store.saveCredential(credential)
        _ = await state.openScreenSharing(hostname: "fixture.invalid", port: 5900, username: "fixture", password: "old", audio: false, host: nil, credentialID: credential.id)
        let linked = try XCTUnwrap(state.screenSharingRuntimes.values.first { $0 !== runtime })
        defer { linked.disconnect() }
        try await waitUntil { linked.canSendLoginPassword }
        credential.password = "new#"; try await store.saveCredential(credential)
        await state.enterScreenSharingLoginPassword(sessionID: linked.descriptor.id)
        XCTAssertEqual(Array(enteredKeys(directory).suffix(5)), expectedKeys("new#"))
    }

    func testNativeToolbarButtonUsesSessionPassword() async throws {
        let (directory, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(vaultStore: try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite")), screenSharingLaunch: launch)
        _ = await state.openScreenSharing(hostname: "fixture.invalid", port: 5900, username: "fixture", password: "Toolbar!", audio: false, host: nil)
        let runtime = try XCTUnwrap(state.screenSharingRuntimes.values.first)
        defer { runtime.disconnect() }
        runtime.setClipboardSyncEnabled(false)
        try await waitUntil { runtime.canSendLoginPassword }
        let defaultsName = "TermPilot-login-ui-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(false, forKey: "screenSharingClipboardSyncEnabled")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var loginButtonFrame = CGRect.zero
        let view = NSHostingView(rootView: ScreenSharingPane(runtime: runtime, workspaceID: try XCTUnwrap(state.activeWorkspaceID), isActive: true)
            .environmentObject(state).defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .preferredColorScheme(.dark)
            .frame(width: 1100, height: 650)
            .overlayPreferenceValue(ScreenSharingLoginButtonBounds.self) { anchor in
                GeometryReader { geometry in
                    Color.clear.onAppear {
                        if let anchor { loginButtonFrame = geometry[anchor] }
                    }
                }.allowsHitTesting(false)
            }
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        settle()
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        settle()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/termpilot-hp-login-toolbar-before.png"))
        }
        XCTAssertEqual(runtime.lifecycle, .connected)
        XCTAssertTrue(runtime.canSendLoginPassword)
        // Click the actual rendered control instead of a fixed pixel offset.
        XCTAssertFalse(loginButtonFrame.isEmpty)
        let point = view.convert(NSPoint(x: loginButtonFrame.midX,
            y: view.isFlipped ? loginButtonFrame.midY : view.bounds.maxY - loginButtonFrame.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let down = try event(.leftMouseDown)
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        window.sendEvent(down)
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                   inMode: .default, dequeue: true) { window.sendEvent(up) }
        try await waitUntil { !runtime.loginPasswordStatus.isEmpty && !runtime.isEnteringLoginPassword }
        XCTAssertEqual(enteredKeys(directory), expectedKeys("Toolbar!"))
        settle()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/termpilot-hp-login-toolbar.png"))
        }
        runtime.setVisible(false)
        XCTAssertNil(runtime.beginLoginPasswordInput())
    }

    func testLoginIsUnavailableForDisconnectedStandardVNCAndRDP() async throws {
        let (directory, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in [ScreenSharingMode.standardVNC, .rdp] {
            var descriptor = SessionDescriptor(kind: .screenSharing, title: "Fixture", hostname: "fixture.invalid", username: "fixture")
            descriptor.screenSharingMode = mode
            let runtime = ScreenSharingSessionRuntime(descriptor: descriptor, pasteboard: NSPasteboard(name: .init(UUID().uuidString)))
            XCTAssertNil(runtime.beginLoginPasswordInput())
            if mode == .rdp {
                try FileManager.default.copyItem(at: launch.executable, to: directory.appendingPathComponent("termpilot-rdp"))
            }
            runtime.connect(password: "fixture", launch: launch)
            try await waitUntil { runtime.lifecycle == .connected && runtime.hasReceivedFrame }
            XCTAssertFalse(runtime.canSendLoginPassword)
            XCTAssertNil(runtime.beginLoginPasswordInput())
            runtime.disconnect()
        }
    }
}
