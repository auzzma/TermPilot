import Foundation
import TermPilotDomain
import TermPilotTestSupport
@testable import TermPilotApp
import XCTest

final class AIServerScopeTests: XCTestCase {
    @MainActor
    func testServerChatsKeepIndependentDraftsAndStreamEvents() {
        let root = AIClient()
        let a = Fixtures.host(label: "Server A")
        let b = Fixtures.host(label: "Server B")
        let da = SessionDescriptor(kind: .ssh, title: a.label, hostID: a.id)
        let db = SessionDescriptor(kind: .ssh, title: b.label, hostID: b.id)
        let ca = root.chat(for: da, host: a)
        let cb = root.chat(for: db, host: b)
        ca.draft = "A 的草稿"; cb.draft = "B 的草稿"
        ca.attachments = [URL(fileURLWithPath: "/tmp/a.txt")]
        ca.conversation = ["id": "chat-a", "scope": ca.boundScope!]
        cb.conversation = ["id": "chat-b", "scope": cb.boundScope!]
        root.dispatchEvent(["type": "delta", "conversationId": "chat-a", "text": "only A"])
        root.dispatchEvent(["type": "approval", "conversationId": "chat-a", "requestId": "approval-a"])
        XCTAssertEqual(ca.streaming, "only A")
        XCTAssertEqual(cb.streaming, "")
        XCTAssertEqual(ca.interactions.count, 1)
        XCTAssertTrue(cb.interactions.isEmpty)
        XCTAssertEqual(root.chat(for: da, host: a).draft, "A 的草稿")
        XCTAssertEqual(root.chat(for: db, host: b).draft, "B 的草稿")
        XCTAssertTrue(cb.attachments.isEmpty)
        let reconnected = SessionDescriptor(kind: .ssh, title: a.label, hostID: a.id)
        XCTAssertTrue(root.chat(for: reconnected, host: a) === ca)
        root.settings = ["mode": "confirm"]
        XCTAssertEqual(ca.settings["mode"] as? String, "confirm")
        XCTAssertEqual(cb.settings["mode"] as? String, "confirm")
    }
}
