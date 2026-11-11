import AppKit
import Darwin
import Foundation
import TermPilotDomain
@testable import TermPilotScreenSharing
import XCTest

/// Opt-in, read-only acceptance on two explicitly selected test Macs. Credentials
/// arrive through a private FIFO, never through arguments, environment or files.
final class MediaBrokerLiveTests: XCTestCase {
    private struct Target: Decodable {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    @MainActor
    private func waitForFrames(_ runtimes: [ScreenSharingSessionRuntime], replacing oldPID: Int32? = nil) async throws {
        let deadline = Date().addingTimeInterval(95)
        while Date() < deadline {
            for runtime in runtimes {
                if case .failed(let message) = runtime.lifecycle {
                    throw NSError(domain: "MediaBrokerLive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                }
            }
            if runtimes.allSatisfy({ $0.lifecycle == .connected && $0.hasReceivedFrame &&
                $0.mediaBrokerProcessID != nil && $0.mediaBrokerProcessID != oldPID }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "MediaBrokerLive", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for both native sessions to receive frames"])
    }

    @MainActor
    func testTwoNativeSessionsRecoverAfterSharedServiceTermination() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let configPath = environment["TERMPILOT_LIVE_HP_CONFIG_PATH"],
              let enginePath = environment["TERMPILOT_TEST_ENGINE"] else {
            throw XCTSkip("Requires two authorized live Macs and a private configuration FIFO")
        }
        var info = stat()
        guard lstat(configPath, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw NSError(domain: "MediaBrokerLive", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Configuration must use a private FIFO owned by this user"])
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: configPath))
        let data = try XCTUnwrap(try handle.readToEnd())
        try handle.close()
        let targets = try JSONDecoder().decode([Target].self, from: data)
        XCTAssertEqual(targets.count, 2)
        let launch = ScreenSharingEngineLaunch(executable: URL(fileURLWithPath: enginePath),
            lockDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("com.termpilot.screen-sharing"))
        var recoveries = [0, 0]
        let runtimes = targets.enumerated().map { index, target in
            var descriptor = SessionDescriptor(id: UUID(), kind: .screenSharing, title: "Media broker acceptance",
                hostname: target.host, port: target.port, username: target.username)
            descriptor.screenSharingMode = .highPerformance
            descriptor.screenSharingAudio = false
            let runtime = ScreenSharingSessionRuntime(descriptor: descriptor,
                pasteboard: NSPasteboard(name: .init("TermPilot-media-test-\(UUID())")))
            runtime.setClipboardSyncEnabled(false)
            runtime.setClipboardFocused(false)
            runtime.onMediaServiceInterrupted = { [weak runtime] in
                recoveries[index] += 1
                runtime?.connect(password: target.password, launch: launch)
            }
            return runtime
        }
        defer { runtimes.forEach { $0.disconnect() } }
        for (runtime, target) in zip(runtimes, targets) { runtime.connect(password: target.password, launch: launch) }
        try await waitForFrames(runtimes)
        let oldPID = try XCTUnwrap(runtimes[0].mediaBrokerProcessID)
        XCTAssertGreaterThan(oldPID, 1)
        XCTAssertEqual(runtimes[1].mediaBrokerProcessID, oldPID)
        XCTAssertEqual(Darwin.kill(oldPID, SIGKILL), 0)
        try await waitForFrames(runtimes, replacing: oldPID)
        XCTAssertEqual(recoveries, [1, 1])
        XCTAssertEqual(runtimes[0].mediaBrokerProcessID, runtimes[1].mediaBrokerProcessID)
        runtimes[0].disconnect()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(runtimes[1].lifecycle, .connected)
        runtimes[0].connect(password: targets[0].password, launch: launch)
        try await waitForFrames(runtimes)
        XCTAssertEqual(recoveries, [1, 1])
    }
}
