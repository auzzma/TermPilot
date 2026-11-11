import AppKit
import Foundation
import TermPilotDomain
import TermPilotRemote
@testable import TermPilotTerminal
import TermPilotTestSupport
import XCTest

final class TerminalReconnectIntegrationTests: XCTestCase {
    /// Uses an independent SSH server and the shipped engine. The window is
    /// never shown; this checks native process/lifecycle wiring, not UI gestures.
    @MainActor
    func testNativeTerminalReconnectsWithFreshPrivateConfiguration() async throws {
        guard let engine = ProcessInfo.processInfo.environment["TERMPILOT_TEST_ENGINE"] else {
            throw XCTSkip("Set TERMPILOT_TEST_ENGINE to run the native SSH process integration")
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = Process()
        let input = Pipe(), output = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        fixture.arguments = ["node", root.appendingPathComponent("tests/node/native-worker.test.cjs").path, "--fixture"]
        fixture.standardInput = input
        fixture.standardOutput = output
        try fixture.run()
        defer {
            try? input.fileHandleForWriting.close()
            fixture.waitUntilExit()
        }
        let announcement = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output.fileHandleForReading.availableData) as? [String: Any]
        )
        let port = try XCTUnwrap(announcement["port"] as? Int)
        let directory = try XCTUnwrap(announcement["directory"] as? String)
        var host = Fixtures.host(hostname: "127.0.0.1", authentication: .password)
        host.port = port
        host.username = "fixture"
        host.password = "fixture-password"
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: host),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: host,
                runtime: SSH2BridgeRuntime(executable: URL(fileURLWithPath: engine)),
                knownHostsFile: URL(fileURLWithPath: directory).appendingPathComponent("known_hosts"),
                autoAcceptHostKeys: true
            ),
            registry: TerminalSessionRegistry()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        defer { runtime.terminate(); window.contentView = nil }

        for cycle in 0..<3 {
            if cycle > 0 { runtime.reconnect() }
            let view = runtime.view()
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            window.contentView = view
            view.resize(cols: 80, rows: 24)
            runtime.startIfDisplayed()
            try await waitUntil("connect cycle \(cycle)", runtime: runtime) { runtime.lifecycle == .connected }
            let marker = "TermPilot-reconnect-\(cycle)-中文"
            runtime.sendText(marker + "\r")
            try await waitUntil("echo cycle \(cycle)", runtime: runtime) {
                // SwiftTerm exports a NUL padding cell after wide characters.
                String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
                    .replacingOccurrences(of: "\0", with: "").contains(marker)
            }
            XCTAssertEqual(runtime.lifecycle, .connected)
            XCTAssertFalse(runtime.connectionLog.contains { $0.message.contains("fixture-password") })
        }
        XCTAssertEqual(runtime.generation, 2)
    }

    @MainActor
    private func waitUntil(_ operation: String, runtime: TerminalSessionRuntime, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "\(operation): \(runtime.lifecycle); \(runtime.connectionLog.map(\.message).joined(separator: " | ")); buffer=\(String(decoding: runtime.view().getTerminal().getBufferAsData(), as: UTF8.self))")
        if !condition() { throw NSError(domain: "TermPilotIntegration", code: 1) }
    }
}
