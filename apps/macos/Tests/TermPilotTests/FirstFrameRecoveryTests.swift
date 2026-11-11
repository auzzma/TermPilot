import Foundation
import XCTest
@testable import TermPilotApp
@testable import TermPilotScreenSharing

final class FirstFrameRecoveryTests: XCTestCase {
    private func fixture(_ mode: String) throws -> (URL, ScreenSharingEngineLaunch) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-first-frame-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = directory.appendingPathComponent("engine.py")
        let script = """
        #!/usr/bin/python3
        import sys,json,struct,pathlib,time
        config=json.loads(sys.stdin.buffer.readline())
        path=pathlib.Path(__file__).with_name(config['host']+'.attempts')
        count=int(path.read_text())+1 if path.exists() else 1
        path.write_text(str(count))
        def emit(event,data=b''):
            raw=json.dumps(dict(payloadLength=len(data),**event)).encode()
            sys.stdout.buffer.write(struct.pack('>I',len(raw))+raw+data)
            sys.stdout.buffer.flush()
        time.sleep(.1)
        if '\(mode)'=='authenticate':
            emit(dict(kind='status',stage='authenticate'))
        else:
            emit(dict(kind='connected',width=1,height=1,tiles=1))
            if config['host']=='healthy.invalid' or ('\(mode)'=='recover' and count>1):
                emit(dict(kind='frame',tile=0,width=1,height=1,yStride=1,uvStride=1,
                    chromaWidth=1,chromaHeight=1,biplanar=False,yLength=1,uLength=1,vLength=1),bytes([128]*3))
        for line in sys.stdin.buffer:
            if json.loads(line).get('kind')=='disconnect': break
        """
        try script.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        return (directory, ScreenSharingEngineLaunch(executable: engine, lockDirectory: directory))
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(8)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition())
    }

    @MainActor
    private func open(_ state: AppState, host: String) async throws -> ScreenSharingSessionRuntime {
        let result = await state.openScreenSharing(hostname: host, port: 5900,
            username: "fixture", password: "fixture", audio: false, host: nil)
        XCTAssertTrue(result)
        let runtime = try XCTUnwrap(state.screenSharingRuntimes.values.first { $0.descriptor.hostname == host })
        runtime.firstFrameTimeout = .milliseconds(300)
        return runtime
    }

    private func attempts(_ directory: URL, _ host: String) throws -> Int {
        try XCTUnwrap(Int(String(contentsOf: directory.appendingPathComponent(host + ".attempts"), encoding: .utf8)))
    }

    @MainActor
    func testMissingFirstFrameReconnectsOnlyThatSessionAndStopsAfterVideoArrives() async throws {
        let (directory, launch) = try fixture("recover")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(screenSharingLaunch: launch)
        let healthy = try await open(state, host: "healthy.invalid")
        let recovering = try await open(state, host: "recovering.invalid")
        defer { state.disconnectScreenSharing(sessionID: healthy.descriptor.id); state.disconnectScreenSharing(sessionID: recovering.descriptor.id) }
        try await wait { healthy.hasReceivedFrame && recovering.hasReceivedFrame }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(try attempts(directory, "recovering.invalid"), 2)
        XCTAssertEqual(try attempts(directory, "healthy.invalid"), 1)
        XCTAssertEqual(healthy.lifecycle, .connected)
        XCTAssertEqual(recovering.lifecycle, .connected)
    }

    @MainActor
    func testPersistentMissingVideoStopsAfterOneRetryAndManualReconnectGetsNewBudget() async throws {
        let (directory, launch) = try fixture("never")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(screenSharingLaunch: launch)
        let runtime = try await open(state, host: "recovering.invalid")
        defer { state.disconnectScreenSharing(sessionID: runtime.descriptor.id) }
        try await wait { if case .failed = runtime.lifecycle { return true }; return false }
        XCTAssertEqual(try attempts(directory, "recovering.invalid"), 2)
        XCTAssertEqual(runtime.connectionDiagnostics, "stage=video; code=firstFrameTimeout")
        state.reconnect(sessionID: runtime.descriptor.id)
        try await wait { if case .failed = runtime.lifecycle { return true }; return false }
        XCTAssertEqual(try attempts(directory, "recovering.invalid"), 4)
    }

    @MainActor
    func testUserDisconnectCancelsFirstFrameRecovery() async throws {
        let (directory, launch) = try fixture("never")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(screenSharingLaunch: launch)
        let runtime = try await open(state, host: "recovering.invalid")
        try await wait { runtime.connectionDiagnostics == "stage=firstFrameRecovery" }
        state.disconnectScreenSharing(sessionID: runtime.descriptor.id)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(runtime.lifecycle, .disconnected)
        XCTAssertEqual(try attempts(directory, "recovering.invalid"), 1)
    }

    @MainActor
    func testAuthenticationStageDoesNotTriggerMediaRetry() async throws {
        let (directory, launch) = try fixture("authenticate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(screenSharingLaunch: launch)
        let runtime = try await open(state, host: "recovering.invalid")
        defer { state.disconnectScreenSharing(sessionID: runtime.descriptor.id) }
        try await wait { runtime.connectionDiagnostics == "stage=authenticate" }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(runtime.lifecycle, .connecting)
        XCTAssertEqual(try attempts(directory, "recovering.invalid"), 1)
    }
}
