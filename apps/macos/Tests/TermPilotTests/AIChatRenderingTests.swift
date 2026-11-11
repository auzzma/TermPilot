import AppKit
import SwiftUI
@testable import TermPilotApp
import XCTest

final class AIChatRenderingTests: XCTestCase {
    @MainActor func testComposerEnterSubmitsAndShiftEnterKeepsDraft() throws {
        let editor = AIChatComposer.Editor(frame: NSRect(x: 0, y: 0, width: 350, height: 100))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor; window.makeFirstResponder(editor)
        defer { window.contentView = nil; window.close() }
        var submits = 0; editor.submit = { submits += 1 }; editor.string = "中文草稿"
        func key(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent { try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)) }
        editor.keyDown(with: try key([])); XCTAssertEqual(submits, 1); XCTAssertEqual(editor.string, "中文草稿")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: try key(.shift)); XCTAssertEqual(submits, 1); XCTAssertTrue(editor.string.contains("\n"))
        editor.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText()); editor.keyDown(with: try key([])); XCTAssertEqual(submits, 1)
    }
    @MainActor func testSharedTranscriptAndApprovalRenderAtSidebarWidths() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        for name in ["complete", "approval", "failed", "streaming"] {
            let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/ai-chat/\(name).json"))
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let input = try XCTUnwrap(fixture["input"] as? [String: Any])
            let client = AIClient(scope: "host:fixture", label: "测试服务器")
            client.selectedAgent = "fixture"
            client.settings = ["providers": [["id": "fixture", "name": "OpenAI", "model": "fixture-model"]], "mode": "confirm"]
            client.conversation = ["id": "fixture-chat", "messages": input["messages"] ?? [], "status": input["status"] ?? "completed"]
            client.streaming = input["streaming"] as? String ?? ""
            client.interactions = input["interactions"] as? [[String: Any]] ?? []
            client.presentation = try XCTUnwrap(fixture["presentation"] as? [[String: Any]])
            for width in name == "complete" ? [350.0, 540.0] : [350.0] {
                try snapshot(AnyView(AIPanel(client: client)), name: "\(name)-\(Int(width))", size: NSSize(width: width, height: 900))
            }
            if name == "complete", let row = client.presentation.last {
                try snapshot(AnyView(AIChatMarkdown(blocks: AIChatBlock.parse(row["blocks"] as? [[String: Any]] ?? [])).padding(14)), name: "markdown", size: NSSize(width: 540, height: 1400))
            }
        }
    }
    @MainActor private func snapshot(_ content: AnyView, name: String, size: NSSize) throws {
        let started = Date()
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .topLeading).environment(\.colorScheme, .dark).background(Color(nsColor: .textBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])); XCTAssertGreaterThan(png.count, 1000)
        if let dir = ProcessInfo.processInfo.environment["TERMPILOT_AI_SNAPSHOT_DIR"] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true); try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chat-\(name).png")) }
        print("Chat snapshot \(name): \(Date().timeIntervalSince(started)) seconds")
    }
}
