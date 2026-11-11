import AppKit
import SwiftUI
@testable import TermPilotApp
import XCTest

@MainActor
final class BatchJobTabTests: XCTestCase {
    func testDoubleClickRenamesRunningJobAndEscapeCancels() throws {
        let state = AppState(), workspace = state.batchJobs
        let first = workspace.selected, second = workspace.newJob()
        first.running = true
        let host = NSHostingView(rootView: BatchWorkspaceView().environmentObject(workspace).environmentObject(state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close(); workspace.shutdown() }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.10)) }
        settle()
        let point = host.convert(CGPoint(x: 48, y: host.isFlipped ? 24 : host.bounds.maxY - 24), to: nil)
        func click(_ count: Int) throws {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            }
            let down = try event(.leftMouseDown)
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            window.sendEvent(down)
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                        inMode: .default, dequeue: true) { window.sendEvent(up) }
        }
        func key(_ characters: String, code: UInt16) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
            settle()
        }
        func edit(_ name: String) throws {
            try click(1); try click(2); settle()
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertTrue(editor.isFieldEditor)
            XCTAssertEqual(editor.string, first.title)
            editor.selectAll(nil)
            editor.insertText(name, replacementRange: editor.selectedRange())
        }
        try edit("  巡检 A  ")
        try key("\r", code: 36)
        XCTAssertTrue(workspace.selected === first)
        XCTAssertEqual(first.title, "巡检 A")
        try edit("取消后的名称")
        try key("\u{1b}", code: 53)
        XCTAssertEqual(first.title, "巡检 A")
        first.rename(to: "  \n")
        XCTAssertEqual(first.title, "巡检 A")
        XCTAssertTrue(first.running)
        XCTAssertNotEqual(second.title, first.title)
    }

    func testLocalDragMovesJobAtEitherEndWithoutChangingTheActiveJob() async throws {
        let workspace = BatchJobWorkspace()
        let first = workspace.selected, second = workspace.newJob(), third = workspace.newJob()
        workspace.selected = second
        first.running = true
        first.rename(to: "升级")
        first.job.script.body = "original draft"
        third.rename(to: first.title)
        defer { workspace.shutdown() }

        func drop(_ source: BatchJobController, x: CGFloat, expected: [UUID]) async throws {
            let frames = Dictionary(uniqueKeysWithValues: workspace.jobs.enumerated().map { index, job in
                (job.id, CGRect(x: index * 100, y: 0, width: 92, height: 28))
            })
            let delegate = BatchJobTabDrop(workspace: workspace, frames: frames, indicatorX: .constant(nil))
            let provider = NSItemProvider()
            let payload = BatchJobTabDrag(id: source.id)
            provider.register(payload)
            XCTAssertTrue(delegate.accept(provider, at: x))
            let deadline = Date().addingTimeInterval(2)
            while workspace.jobs.map(\.id) != expected && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(workspace.jobs.map(\.id), expected)
        }
        try await drop(first, x: 400, expected: [second.id, third.id, first.id])
        try await drop(first, x: 10, expected: [first.id, second.id, third.id])
        try await drop(third, x: 55, expected: [first.id, third.id, second.id])
        let foreign = BatchJobWorkspace()
        workspace.move(foreign.selected.id, before: first.id)
        workspace.move(first.id, before: foreign.selected.id)
        XCTAssertEqual(workspace.jobs.map(\.id), [first.id, third.id, second.id])
        XCTAssertTrue(workspace.selected === second)
        XCTAssertTrue(first.running)
        XCTAssertEqual(first.job.script.body, "original draft")
        XCTAssertEqual(first.title, "升级")
    }
}
