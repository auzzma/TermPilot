import AppKit
import SwiftUI
@testable import TermPilotApp
import XCTest

final class AIProviderModelTests: XCTestCase {
    @MainActor func testUnsavedConnectionAndSearchThenFailureDoNotReuseOldCatalog() async {
        let catalog = AIProviderModelCatalog()
        let draft: [String: Any] = ["baseUrl": "http://127.0.0.1/draft/v1", "apiKey": "synthetic-draft-key", "proxy": "http://127.0.0.1:9999", "model": "manual-model"]
        await catalog.load(provider: draft) { current in
            XCTAssertEqual(current["apiKey"] as? String, "synthetic-draft-key")
            XCTAssertEqual(current["baseUrl"] as? String, draft["baseUrl"] as? String)
            XCTAssertEqual(current["proxy"] as? String, draft["proxy"] as? String)
            return ["model-a", "model-b"]
        }
        XCTAssertEqual(catalog.filtered(" MODEL-B "), ["model-b"])
        XCTAssertTrue(catalog.error.isEmpty)
        await catalog.load(provider: draft) { _ in throw AIError.message("HTTP 401") }
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertTrue(catalog.error.contains("401"))
        XCTAssertFalse(catalog.loading)
        XCTAssertEqual(draft["model"] as? String, "manual-model")
    }

    @MainActor func testDismissedModelRequestDoesNotPublishResults() async {
        let catalog = AIProviderModelCatalog()
        let task = Task { await catalog.load(provider: [:]) { _ in
            try? await Task.sleep(for: .milliseconds(40))
            return ["stale-model"]
        } }
        await Task.yield(); task.cancel(); await task.value
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertFalse(catalog.loading)
    }

    @MainActor func testProviderEditorAndModelPickerRender() throws {
        let provider: [String: Any] = ["name": "Fixture API", "protocol": "chat", "baseUrl": "http://127.0.0.1/v1", "model": "manual-model"]
        let fetch: @MainActor ([String: Any]) async throws -> [String] = { _ in ["model-a", "model-b", "model-long-context"] }
        try snapshot(AnyView(AIProviderEditor(provider: provider, fetchModels: fetch, save: { _ in }, cancel: {})), name: "provider-editor", size: NSSize(width: 800, height: 550))
        try snapshot(AnyView(AIProviderModelPicker(provider: provider, model: .constant("model-b"), fetch: fetch)), name: "provider-models", size: NSSize(width: 440, height: 410))
        try snapshot(AnyView(AIProviderModelPicker(provider: provider, model: .constant("manual-model"), fetch: { _ in throw AIError.message("模型列表认证失败（HTTP 401），请检查 API Key 与访问权限") })), name: "provider-models-error", size: NSSize(width: 440, height: 410))
    }

    @MainActor private func snapshot(_ view: AnyView, name: String, size: NSSize) throws {
        let host = NSHostingView(rootView: view.padding(12).frame(width: size.width, height: size.height).environment(\.colorScheme, .dark).background(Color(nsColor: .textBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])); XCTAssertGreaterThan(png.count, 1000)
        if let directory = ProcessInfo.processInfo.environment["TERMPILOT_AI_SNAPSHOT_DIR"] { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true); try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")) }
    }
}
