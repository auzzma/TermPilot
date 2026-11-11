import AppKit
import SwiftUI
@testable import TermPilotApp
import XCTest

final class AIPanelTests: XCTestCase {
    @MainActor
    func testNativeSettingsAndChatRenderWithoutStartingRuntime() throws {
        let client = AIClient(scope: "host:fixture", label: "测试服务器")
        client.settings = [
            "providers": [["id": "fixture", "name": "测试模型", "protocol": "responses", "baseUrl": "https://example.invalid/v1", "model": "fixture-model", "verifyTls": true, "contextWindow": 32768]],
            "agents": [["id": "codex", "name": "Codex", "kind": "codex", "executable": "/fixture/codex"]],
            "quickMessages": [["id": "explain", "slug": "explain", "name": "解释", "content": "解释当前终端输出"]],
            "selected": "fixture", "mode": "confirm"
        ]
        client.presets = [["kind":"openai","name":"OpenAI","protocol":"chat","baseUrl":"https://api.openai.com/v1"]]
        client.agentCatalog = [["kind":"codex","name":"Codex"],["kind":"claude","name":"Claude Code"],["kind":"copilot","name":"GitHub Copilot CLI","available":false],["kind":"cursor","name":"Cursor","available":false],["kind":"codebuddy","name":"CodeBuddy Code","available":false],["kind":"opencode","name":"OpenCode"]]
        client.configuration = ["commandBlacklist":["\\breboot\\b"]]
        client.conversation = ["id": "fixture-chat", "title": "界面验收", "agent": "fixture", "scope": "host:fixture", "status": "completed", "messages": [["role": "user", "content": "查看服务器状态"], ["role": "assistant", "content": "已读取当前终端。\n\n**中文与 Markdown**"], ["role": "tool", "content": "{\"status\":\"completed\",\"code\":0}"]]]
        for (name, content, size) in [
            ("settings", AnyView(AISettingsView(client: client)), NSSize(width: 760, height: 700)),
            ("agents", AnyView(AISettingsView(client: client, initialTab: .agents)), NSSize(width: 760, height: 700)),
            ("tools", AnyView(AISettingsView(client: client, initialTab: .tools)), NSSize(width: 760, height: 700)),
            ("search", AnyView(AISettingsView(client: client, initialTab: .search)), NSSize(width: 760, height: 700)),
            ("security", AnyView(AISettingsView(client: client, initialTab: .security)), NSSize(width: 760, height: 700)),
            ("chat", AnyView(AIPanel(client: client)), NSSize(width: 480, height: 900)),
            ("chat-narrow", AnyView(AIPanel(client: client)), NSSize(width: 350, height: 640))
        ] {
            let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height).environment(\.colorScheme, .light).background(Color.white))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1000)
            if let directory = ProcessInfo.processInfo.environment["TERMPILOT_AI_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ai-\(name).png"))
            }
            window.contentView = nil
        }
        XCTAssertFalse(client.ready)
    }
}
