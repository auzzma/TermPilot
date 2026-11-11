import AppKit
import Foundation
@testable import TermPilotScreenSharing
import XCTest

@MainActor
final class RDPClipboardTests: XCTestCase {
    func testFirstPastePublishesExistingClipboardAndWaitsForRemoteAcceptance() {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("已有中文文本", forType: .string)
        let sync = RDPClipboardSync(pasteboard: board)
        var commands: [[String: Any]] = []; var ready = 0
        sync.send = { commands.append($0); return true }; sync.ready = { ready += 1 }
        sync.setConnected(true)
        XCTAssertEqual(sync.preparePaste(), .waiting)
        XCTAssertEqual(commands.last?["text"] as? String, "已有中文文本")
        sync.accepted(true)
        XCTAssertEqual(ready, 1); XCTAssertEqual(sync.preparePaste(), .ready)
    }
    func testFailedSendBlocksPasteAndStaleAcceptanceCannotReleaseIt() {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("new copy", forType: .string)
        let sync = RDPClipboardSync(pasteboard: board)
        sync.setConnected(true)
        XCTAssertEqual(sync.preparePaste(), .blocked)
        sync.accepted(true, id: "older-offer")
        XCTAssertEqual(sync.preparePaste(), .blocked)
    }
    func testOnlyMatchingOfferCanReleasePaste() {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("copy", forType: .string)
        let sync = RDPClipboardSync(pasteboard: board)
        var id: String?; sync.send = { if let offer = $0["offerId"] as? String { id = offer }; return true }
        sync.setConnected(true)
        XCTAssertEqual(sync.preparePaste(), .waiting)
        sync.accepted(true, id: "initial-format-ack")
        XCTAssertEqual(sync.preparePaste(), .waiting)
        sync.accepted(true, id: id)
        XCTAssertEqual(sync.preparePaste(), .ready)
    }
    func testLateTextAndFileRepliesCannotReplaceNewLocalCopy() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let sync = RDPClipboardSync(pasteboard: board); sync.send = { _ in true }; sync.setConnected(true)
        sync.preparing()
        board.clearContents(); board.setString("较新的本地复制", forType: .string)
        sync.receive(text: "过期远端内容")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to: path); defer { try? FileManager.default.removeItem(at: path) }
        sync.receive(paths: [path.path])
        XCTAssertEqual(board.string(forType: .string), "较新的本地复制")
    }
    func testNewLocalCopyWinsWhileFileValidationIsPending() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let sync = RDPClipboardSync(pasteboard: board); sync.send = { _ in true }; sync.setConnected(true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to: path); defer { try? FileManager.default.removeItem(at: path) }
        sync.preparing(); sync.receive(paths: [path.path])
        board.clearContents(); board.setString("newer local copy", forType: .string)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(board.string(forType: .string), "newer local copy")
    }
    func testNewRemoteCopyInvalidatesPendingFileValidationEvenWhenPasteboardIsUnchanged() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("previous local value", forType: .string)
        let sync = RDPClipboardSync(pasteboard: board); sync.send = { _ in true }; sync.setConnected(true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to: path); defer { try? FileManager.default.removeItem(at: path) }
        sync.preparing(); sync.receive(paths: [path.path])
        sync.preparing()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(board.string(forType: .string), "previous local value")
        sync.receive(text: "latest remote value")
        XCTAssertEqual(board.string(forType: .string), "latest remote value")
    }
    func testCompletedFilesUseNativeURLsAndInactiveSessionCannotWriteClipboard() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let sync = RDPClipboardSync(pasteboard: board); sync.send = { _ in true }; sync.setConnected(true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to: path); defer { try? FileManager.default.removeItem(at: path) }
        sync.preparing(); sync.receive(paths: [path.path])
        for _ in 0..<100 { if (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.path == path.path { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual((board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.path, path.path)
        let count = board.changeCount
        sync.preparing(); sync.setSelected(false); sync.receive(text: "inactive")
        XCTAssertEqual(board.changeCount, count)
    }
}
