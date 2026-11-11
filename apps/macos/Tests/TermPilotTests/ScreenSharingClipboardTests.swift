import AppKit
import Foundation
@testable import TermPilotScreenSharing
import XCTest

@MainActor
final class ScreenSharingClipboardTests: XCTestCase {
    private var board: NSPasteboard!
    private var sync: ScreenSharingClipboardSync!
    private var commands: [[String: Any]] = []
    private var time = Date(timeIntervalSince1970: 100)
    private var ready = 0
    private var lastStatus = ""

    override func setUp() async throws {
        board = NSPasteboard.withUniqueName()
        board.setString("initial local", forType: .string)
        sync = ScreenSharingClipboardSync(pasteboard: board, now: { [unowned self] in self.time })
        sync.send = { [unowned self] in self.commands.append($0); return true }
        sync.pasteReady = { [unowned self] in self.ready += 1 }
        sync.status = { [unowned self] in self.lastStatus = $0 }
        sync.setEnabled(true)
        sync.setConnected(true)
        sync.setFocused(true)
        commands.removeAll()
    }

    override func tearDown() async throws {
        sync.setConnected(false)
        board.releaseGlobally()
        sync = nil
        board = nil
    }

    private func copy(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }
    private func requestID() throws -> String {
        try XCTUnwrap(commands.last(where: { $0["kind"] as? String == "clipboardFetch" })?["requestID"] as? String)
    }
    private var sends: [String] { commands.compactMap { $0["kind"] as? String == "clipboardSend" ? $0["text"] as? String : nil } }

    func testConnectDoesNotOverwriteEitherClipboardAndLocalCopySendsOnce() throws {
        sync.tick()
        XCTAssertTrue(commands.isEmpty)
        copy("中文\ntrailing spaces  \n")
        sync.tick(); sync.tick()
        XCTAssertEqual(sends, ["中文\ntrailing spaces  \n"])
        sync.receive(id: try requestID(), text: sends[0])
        sync.remoteChanged()
        sync.receive(id: try requestID(), text: sends[0])
        sync.tick()
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(board.string(forType: .string), sends[0])
    }

    func testRemoteChangeIsAppliedWithoutEchoAndPreservesWhitespace() throws {
        sync.remoteChanged()
        let text = "远端\n  ending \r\n"
        sync.receive(id: try requestID(), text: text)
        sync.tick()
        XCTAssertEqual(board.string(forType: .string), text)
        XCTAssertTrue(sends.isEmpty)
    }

    func testNewLocalCopyWinsOverDelayedRemoteReply() throws {
        sync.remoteChanged()
        let stale = try requestID()
        copy("new local")
        sync.receive(id: stale, text: "old remote")
        XCTAssertEqual(board.string(forType: .string), "new local")
        XCTAssertEqual(sends, ["new local"])
    }

    func testDisabledAndHiddenSessionRejectLateRepliesAndStopBothDirections() throws {
        for hide in [false, true] {
            sync.setEnabled(true); sync.setSelected(true)
            sync.remoteChanged()
            let stale = try requestID()
            if hide { sync.setSelected(false) } else { sync.setEnabled(false) }
            commands.removeAll()
            copy("keep local")
            sync.receive(id: stale, text: "must not apply")
            sync.remoteChanged(); sync.tick()
            XCTAssertTrue(commands.isEmpty)
            XCTAssertEqual(board.string(forType: .string), "keep local")
        }
    }

    func testToggleBackOnDoesNotAcceptPreviousRequestOrPublishOldClipboard() throws {
        sync.remoteChanged()
        let old = try requestID()
        sync.setEnabled(false)
        copy("copied while disabled")
        sync.setEnabled(true)
        commands.removeAll()
        sync.receive(id: old, text: "old reply")
        sync.tick()
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "copied while disabled")
    }

    func testBackgroundLocalCopyWaitsForFocusAndInactiveRemoteChangeIsIgnored() {
        sync.setFocused(false)
        copy("copied in another app")
        sync.tick(); sync.remoteChanged()
        XCTAssertTrue(commands.isEmpty)
        sync.setFocused(true)
        XCTAssertEqual(sends, ["copied in another app"])
    }

    func testRemoteCopyCanFinishAfterSwitchingAppsButCannotOverwriteNewLocalCopy() throws {
        sync.remoteCopy()
        sync.setFocused(false)
        sync.remoteChanged()
        sync.receive(id: try requestID(), text: "copied remotely")
        XCTAssertEqual(board.string(forType: .string), "copied remotely")
        time += 2
        commands.removeAll()
        sync.remoteChanged()
        XCTAssertTrue(commands.isEmpty)
    }

    func testPasteWaitsUntilRemoteReadbackMatchesLocalCopy() throws {
        copy("paste me")
        XCTAssertEqual(sync.preparePaste(), .waiting)
        XCTAssertEqual(sends, ["paste me"])
        sync.receive(id: try requestID(), text: "old remote clipboard")
        XCTAssertEqual(ready, 0)
        XCTAssertEqual(board.string(forType: .string), "paste me")
        time += 0.2
        sync.tick()
        sync.receive(id: try requestID(), text: "paste me")
        XCTAssertEqual(ready, 1)
        XCTAssertEqual(sync.preparePaste(), .ready)
    }

    func testRemoteCopyThenImmediateRemotePasteDoesNotUploadStaleLocalText() {
        sync.remoteCopy()
        XCTAssertEqual(sync.preparePaste(), .ready)
        XCTAssertTrue(sends.isEmpty)
    }

    func testUnsupportedOrOversizedClipboardIsNotSentAndPasteIsBlocked() {
        board.clearContents()
        board.setString("file:///fixture.txt", forType: .fileURL)
        board.setString("/fixture.txt", forType: .string)
        sync.tick()
        XCTAssertEqual(sync.preparePaste(), .blocked)
        copy(String(repeating: "a", count: 524_289))
        sync.tick()
        XCTAssertEqual(sync.preparePaste(), .blocked)
        XCTAssertTrue(sends.isEmpty)
    }

    func testCopyingNewTextCancelsPasteWaitingForPreviousText() {
        copy("first paste")
        XCTAssertEqual(sync.preparePaste(), .waiting)
        var cancelled = 0
        sync.cancelPaste = { cancelled += 1 }
        copy("second copy")
        sync.tick()
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(sends, ["first paste", "second copy"])
    }

    func testTimeoutDoesNotApplyLateTextOrReleasePasteKeys() throws {
        copy("paste me")
        XCTAssertEqual(sync.preparePaste(), .waiting)
        let id = try requestID()
        time += 6
        sync.tick()
        sync.receive(id: id, text: "late response")
        XCTAssertEqual(ready, 0)
        XCTAssertEqual(board.string(forType: .string), "paste me")
        XCTAssertTrue(lastStatus.contains("timed out"))
    }

    func testPollingFindsRemoteCopyWithoutNotificationAndDoesNotOverwriteOnFirstPoll() throws {
        time += 1.1
        sync.tick()
        sync.receive(id: try requestID(), text: "preexisting remote")
        XCTAssertEqual(board.string(forType: .string), "initial local")
        time += 1.1
        sync.tick()
        sync.receive(id: try requestID(), text: "copied via remote menu")
        XCTAssertEqual(board.string(forType: .string), "copied via remote menu")
        XCTAssertTrue(sends.isEmpty)
    }

    func testNonTextRemoteResponseCompletesRequestWithoutClearingLocalClipboard() throws {
        sync.remoteChanged()
        let first = try requestID()
        sync.receive(id: first, text: nil)
        sync.remoteChanged()
        XCTAssertNotEqual(try requestID(), first)
        XCTAssertEqual(board.string(forType: .string), "initial local")
    }
}
