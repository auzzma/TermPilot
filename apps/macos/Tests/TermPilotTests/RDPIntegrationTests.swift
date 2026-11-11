import AppKit
import Foundation
import SwiftUI
import TermPilotDomain
@testable import TermPilotApp
@testable import TermPilotScreenSharing
import XCTest

@MainActor
final class RDPIntegrationTests: XCTestCase {
    func testRDPProxyFailureCannotSilentlyReturnToPasswordPrompt() async throws {
        let unexpected = "RDP connection ended before a desktop was received. Reconnect or update the application."
        let workerFailure = "RDP connection worker stopped unexpectedly. Reconnect or update the application."
        for (event, expected) in [
            (["kind":"error", "code":"rdpWorkerStopped", "message":workerFailure], workerFailure),
            (["kind":"disconnected", "message":"Fixture server ended negotiation"], "Fixture server ended negotiation"),
            ([:], unexpected),
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-failure-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = directory.appendingPathComponent("termpilot-rdp")
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            try """
            #!/usr/bin/python3
            import sys,json,struct
            cfg=json.loads(sys.stdin.buffer.readline())
            assert cfg['proxy']['type']=='socks5'
            assert cfg['proxy']['password']=='fixture-proxy-password'
            assert cfg['password']=='fixture-windows-password'
            event=json.loads('\(encoded)')
            if event:
                event['payloadLength']=0
                data=json.dumps(event).encode()
                sys.stdout.buffer.write(struct.pack('>I',len(data))+data)
                sys.stdout.buffer.flush()
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: script.path)
            var descriptor = SessionDescriptor(kind: .screenSharing, title: "Fixture RDP", hostname: "fixture.invalid", port: 3389, username: "fixture")
            descriptor.screenSharingMode = .rdp
            descriptor.customProxyConfigured = true
            let runtime = ScreenSharingSessionRuntime(descriptor: descriptor, proxyConfiguration:
                SSHProxyConfiguration(type: .socks5, host: "proxy.invalid", port: 1080, username: "proxy-user", password: "fixture-proxy-password"))
            defer { runtime.disconnect() }
            runtime.connect(password: "fixture-windows-password", launch: ScreenSharingEngineLaunch(executable: script, lockDirectory: directory))
            let deadline = Date().addingTimeInterval(10)
            while runtime.isActive && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            // Wait for the process-exit callback as well as the final buffered event.
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(runtime.lifecycle, .failed(expected))
            XCTAssertFalse(runtime.hasReceivedFrame)
        }
    }

    func testRDPQuickConnectFitsBothAppearances() throws {
        for dark in [false, true] {
            let view = NSHostingView(rootView: QuickConnectView(initialKind: .rdp)
                .environmentObject(AppState()).environment(\.locale, Locale(identifier: "zh-Hans"))
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color.white))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = view.fittingSize
            XCTAssertLessThanOrEqual(size.width, 600)
            XCTAssertLessThanOrEqual(size.height, 800)
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            if let root = ProcessInfo.processInfo.environment["TERMPILOT_RDP_UI_SNAPSHOTS"] {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: root).appendingPathComponent(dark ? "quick-connect-dark.png" : "quick-connect-light.png"))
            }
        }
    }

    func testAuthorizedWindowsThroughNativeRuntime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["TERMPILOT_RDP_LIVE_ROOT"], let python = environment["TERMPILOT_TEST_PYTHON"],
              let host = environment["TERMPILOT_TEST_RDP_HOST"], !host.isEmpty,
              let expectedFingerprint = environment["TERMPILOT_TEST_RDP_FINGERPRINT"],
              expectedFingerprint.count == 64 else {
            throw XCTSkip("Opt-in test requires the explicitly authorized Windows fixture")
        }
        // Read the existing fixture credential directly into a private pipe. It is
        // never placed in argv, environment, a temporary config file or test output.
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import sys,json;sys.path.insert(0,sys.argv[1]+'/tests/migration-poc');from remote_config import configuration;print(json.dumps(configuration('ssh',sys.argv[2])))", root, host]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let username = try XCTUnwrap(config["username"] as? String)
        let password = try XCTUnwrap(config["password"] as? String)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        var descriptor = SessionDescriptor(kind: .screenSharing, title: "RDP acceptance", hostname: host, port: 3389, username: username)
        descriptor.screenSharingMode = .rdp; descriptor.screenSharingAudio = false
        let runtime = ScreenSharingSessionRuntime(descriptor: descriptor, pasteboard: board)
        defer { runtime.disconnect() }
        runtime.connect(password: password, launch: ScreenSharingEngineLaunch(
            executable: URL(fileURLWithPath: root + "/engines/rdp/target/release/termpilot-rdp"),
            lockDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-RDP-test")))
        let deadline = Date().addingTimeInterval(50)
        while !runtime.hasReceivedFrame && Date() < deadline {
            if let certificate = runtime.certificatePrompt {
                // Supply an independently approved pin with the opt-in fixture.
                let expected = expectedFingerprint.lowercased()
                XCTAssertEqual(certificate.fingerprint, expected)
                runtime.answerCertificate(certificate.fingerprint == expected)
            }
            if case .failed(let message) = runtime.lifecycle { XCTFail(message); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(runtime.lifecycle, .connected)
        XCTAssertTrue(runtime.hasReceivedFrame)
        XCTAssertFalse(runtime.mailbox.takeFrames().isEmpty)
        let renderer = ScreenSharingMetalView(runtime: runtime)
        XCTAssertTrue(renderer.isRendererReady)
        runtime.resizeRDP(width: 1280, height: 720)
        let resizeDeadline = Date().addingTimeInterval(30)
        while runtime.desktopSize != CGSize(width: 1280, height: 720) && Date() < resizeDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(runtime.desktopSize, CGSize(width: 1280, height: 720))
        runtime.disconnect()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(runtime.lifecycle, .disconnected)
        XCTAssertFalse(runtime.hasReceivedFrame)
    }
}
