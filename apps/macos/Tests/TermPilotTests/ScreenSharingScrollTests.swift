import AppKit
import TermPilotDomain
@testable import TermPilotScreenSharing
import XCTest

final class ScreenSharingScrollTests: XCTestCase {
    @MainActor
    func testNativeSurfaceSendsFullSwipeToEngineAndIgnoresLetterbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hp-scroll-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py")
        let log = directory.appendingPathComponent("commands.jsonl")
        try """
        #!/usr/bin/python3
        import sys,json,pathlib
        cfg=json.loads(sys.stdin.buffer.readline())
        assert cfg['mode']=='highPerformance'
        with open(pathlib.Path(__file__).with_name('commands.jsonl'),'w',buffering=1) as log:
            for line in sys.stdin:
                command=json.loads(line)
                if command['kind']=='disconnect': break
                log.write(json.dumps(command)+'\\n')
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let descriptor = SessionDescriptor(kind: .screenSharing, title: "Scroll fixture", hostname: "fixture.invalid", port: 5900, username: "fixture")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let runtime = ScreenSharingSessionRuntime(descriptor: descriptor, pasteboard: board)
        runtime.connect(password: "fixture", launch: ScreenSharingEngineLaunch(executable: script, lockDirectory: directory))
        defer { runtime.disconnect() }
        let view = ScreenSharingMetalView(runtime: runtime)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -240, wheel2: 0, wheel3: 0))
        cg.location = CGPoint(x: 960, y: (NSScreen.main?.frame.height ?? 1080) - 540)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        view.frame.size = CGSize(width: 1920, height: 1080)
        XCTAssertNotNil(ScreenSharingGeometry.remotePoint(view.convert(event.locationInWindow, from: nil), in: view.bounds))
        view.scrollWheel(with: event)
        view.releaseInput()
        // A black margin must not scroll the previous remote pointer location.
        view.frame.size.height = 3000
        cg.location.y = (NSScreen.main?.frame.height ?? 1080) - 100
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        let deadline = Date().addingTimeInterval(5)
        var commands: [[String: Any]] = []
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            commands = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            } ?? []
        } while !commands.contains(where: { $0["kind"] as? String == "release" }) && Date() < deadline
        XCTAssertTrue(commands.contains(where: { $0["kind"] as? String == "release" }))
        let scrolls = commands.filter { $0["kind"] as? String == "scroll" }.compactMap { $0["dy"] as? Int }
        XCTAssertEqual(scrolls, Array(repeating: 10, count: 24))
        XCTAssertEqual(commands.filter { $0["kind"] as? String == "pointer" }.count, 1)
    }

    func testFastSwipePreservesDistanceAndSplitsEngineLimit() {
        var state = ScreenSharingScrollState()
        XCTAssertEqual(state.consume(deltaY: -240, precise: true, timestamp: 1), Array(repeating: 10, count: 24))
        XCTAssertEqual(state.consume(deltaY: 4.5, precise: true, timestamp: 1.01), [-4])
        XCTAssertEqual(state.consume(deltaY: 0.5, precise: true, timestamp: 1.02), [-1])
    }

    func testSmallDeltasAccumulateIncludingMomentumTail() {
        var state = ScreenSharingScrollState()
        let commands = (0..<20).flatMap { index in
            state.consume(deltaY: -0.15, precise: true, timestamp: Double(index) / 120)
        }
        XCTAssertEqual(commands, [1, 1, 1])
        // An end marker must not discard the fraction needed by momentum.
        XCTAssertEqual(state.consume(deltaY: -0.6, precise: true, timestamp: 0.2), [])
        XCTAssertEqual(state.consume(deltaY: 0, precise: true, timestamp: 0.21), [])
        XCTAssertEqual(state.consume(deltaY: -0.4, precise: true, timestamp: 0.22), [1])
    }

    func testDistanceDoesNotDependOnEventFrequency() {
        for samples in [10, 30, 60, 120] {
            var state = ScreenSharingScrollState()
            let total = (0..<samples).flatMap { index in
                state.consume(deltaY: -600 / Double(samples), precise: true, timestamp: Double(index) / Double(samples))
            }.reduce(0, +)
            XCTAssertEqual(total, 600, "\(samples) events per gesture")
        }
    }

    func testDirectionGestureIdleAndFocusResetDiscardOldRemainder() {
        var state = ScreenSharingScrollState()
        XCTAssertEqual(state.consume(deltaY: -0.9, precise: true, timestamp: 0), [])
        XCTAssertEqual(state.consume(deltaY: 1, precise: true, timestamp: 0.01), [-1])
        _ = state.consume(deltaY: -0.9, precise: true, timestamp: 0.02)
        XCTAssertEqual(state.consume(deltaY: -0.1, precise: true, timestamp: 0.03, startsGesture: true), [])
        _ = state.consume(deltaY: -0.8, precise: true, timestamp: 0.04)
        XCTAssertEqual(state.consume(deltaY: -0.1, precise: true, timestamp: 1), [])
        _ = state.consume(deltaY: -0.8, precise: true, timestamp: 1.01)
        state.reset()
        XCTAssertEqual(state.consume(deltaY: -0.1, precise: true, timestamp: 1.02), [])
    }

    func testWheelLineUnitsAndDeviceChange() {
        var state = ScreenSharingScrollState()
        _ = state.consume(deltaY: -0.9, precise: true, timestamp: 0)
        XCTAssertEqual(state.consume(deltaY: -0.05, precise: false, timestamp: 0.01), [])
        XCTAssertEqual(state.consume(deltaY: -0.05, precise: false, timestamp: 0.02), [1])
        XCTAssertEqual(state.consume(deltaY: 3, precise: false, timestamp: 0.03), [-10, -10, -10])
    }

    func testNativeAppKitPixelAndLineEvents() throws {
        for (units, input, expected) in [(CGScrollEventUnit.pixel, Int32(-40), [10, 10, 10, 10]), (.line, -4, [10, 10, 10, 10])] {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: input, wheel2: 0, wheel3: 0))
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            var state = ScreenSharingScrollState()
            XCTAssertEqual(state.commands(for: event), expected)
        }
    }

    func testInvalidOrExtremeInputCannotOverflowOrQueueUnboundedWork() {
        var state = ScreenSharingScrollState()
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(state.consume(deltaY: invalid, precise: true, timestamp: 0), [])
        }
        XCTAssertEqual(state.consume(deltaY: -Double.greatestFiniteMagnitude, precise: true, timestamp: 1), Array(repeating: 10, count: 100))
        XCTAssertEqual(state.consume(deltaY: 0, precise: true, timestamp: 1.01), [])
    }
}
