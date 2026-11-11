import Foundation
import XCTest
@testable import TermPilotApp
import TermPilotDomain
import TermPilotPersistence
import TermPilotScreenSharing

final class MediaBrokerRecoveryTests: XCTestCase {
    private func fixture(alwaysFail: Bool, code: String = "mediaBrokerDisconnected") throws -> (URL, ScreenSharingEngineLaunch) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-media-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("engine.py")
        let script = """
        #!/usr/bin/python3
        import sys,json,struct,pathlib,time
        config=json.loads(sys.stdin.buffer.readline())
        path=pathlib.Path(__file__).with_name('attempts')
        attempts=int(path.read_text())+1 if path.exists() else 1
        path.write_text(str(attempts))
        def emit(event,data=b''):
            raw=json.dumps(dict(payloadLength=len(data),**event)).encode()
            sys.stdout.buffer.write(struct.pack('>I',len(raw))+raw+data)
            sys.stdout.buffer.flush()
        if \(alwaysFail ? "True" : "False") or attempts==1:
            if '\(code)'=='sessionVideoRecoveryFailed':
                emit(dict(kind='connected',width=1,height=1,tiles=1))
                emit(dict(kind='frame',tile=0,width=1,height=1,yStride=1,uvStride=1,
                    chromaWidth=1,chromaHeight=1,biplanar=False,yLength=1,uLength=1,vLength=1),bytes([128]*3))
                time.sleep(.1)
                emit(dict(kind='sessionRecovery',stage='renegotiate'))
            emit(dict(kind='error',code='\(code)'))
            sys.exit(1)
        emit(dict(kind='connected',width=1920,height=1080,tiles=1))
        for line in sys.stdin.buffer:
            if json.loads(line).get('kind')=='disconnect': break
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return (directory, ScreenSharingEngineLaunch(executable: helper, lockDirectory: directory))
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(12)
        while !condition() && Date() < until { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertTrue(condition())
    }

    @MainActor
    private func open(_ launch: ScreenSharingEngineLaunch) async throws -> (AppState, ScreenSharingSessionRuntime) {
        let state = AppState(vaultStore: try VaultStore(databaseURL: launch.executable.deletingLastPathComponent().appendingPathComponent("vault.sqlite")), screenSharingLaunch: launch)
        let opened = await state.openScreenSharing(hostname: "recovery.invalid", port: 5900,
            username: "fixture", password: "fixture-password", audio: false, host: nil)
        XCTAssertTrue(opened)
        return (state, try XCTUnwrap(state.screenSharingRuntimes.values.first))
    }

    @MainActor
    func testSharedServiceFailureReconnectsThroughAppState() async throws {
        let (directory, launch) = try fixture(alwaysFail: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, runtime) = try await open(launch)
        try await wait { runtime.lifecycle == .connected }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("attempts"), encoding: .utf8), "2")
        XCTAssertEqual(runtime.desktopSize.width, 1920)
        state.disconnectScreenSharing(sessionID: runtime.descriptor.id)
    }

    @MainActor
    func testFailedInPlaceSessionRecoveryAutomaticallyReconnects() async throws {
        let (directory, launch) = try fixture(alwaysFail: false, code: "sessionVideoRecoveryFailed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, runtime) = try await open(launch)
        defer { state.disconnectScreenSharing(sessionID: runtime.descriptor.id) }
        try await wait {
            runtime.lifecycle == .connected &&
                (try? String(contentsOf: directory.appendingPathComponent("attempts"), encoding: .utf8)) == "2"
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("attempts"), encoding: .utf8), "2")
    }

    @MainActor
    func testSessionRecoveryFallbackHasABoundedBudget() async throws {
        let (directory, launch) = try fixture(alwaysFail: true, code: "sessionVideoRecoveryFailed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, runtime) = try await open(launch)
        defer { state.disconnectScreenSharing(sessionID: runtime.descriptor.id) }
        try await wait { if case .failed = runtime.lifecycle { return true }; return false }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("attempts"), encoding: .utf8), "3")
    }

    @MainActor
    func testRepeatedSharedServiceFailureStopsAfterTwoAutomaticRetries() async throws {
        let (directory, launch) = try fixture(alwaysFail: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, runtime) = try await open(launch)
        try await wait { if case .failed = runtime.lifecycle { return true }; return false }
        XCTAssertEqual(runtime.lifecycle, .failed("The shared screen-sharing service stopped. Reconnect this session."))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("attempts"), encoding: .utf8), "3")
        state.disconnectScreenSharing(sessionID: runtime.descriptor.id)
    }

    @MainActor
    func testUserDisconnectCancelsPendingAutomaticRecovery() async throws {
        let (directory, launch) = try fixture(alwaysFail: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, runtime) = try await open(launch)
        try await wait { runtime.connectionDiagnostics == "stage=mediaRecovery" }
        state.disconnectScreenSharing(sessionID: runtime.descriptor.id)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(runtime.lifecycle, .disconnected)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("attempts"), encoding: .utf8), "1")
    }
}
