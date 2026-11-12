import AppKit
import SwiftUI
@testable import TermPilotApp
import XCTest

final class SettingsNavigationTests: XCTestCase {
    @MainActor
    func testOpeningSettingsInResizableMainWindow() throws {
        let state = AppState()
        state.preparePerformanceFixtureForTesting(count: 3)
        let suite = "TermPilot.SettingsNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: RootView(startsAIRuntime: false)
            .environmentObject(state)
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .preferredColorScheme(.dark)
            .frame(minWidth: 900, minHeight: 560))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try clickSettingsEntry(in: host, window: window)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        assertControlsFollowWidth(in: host)
        try assertSettingsViewport(in: host)
        try saveSnapshot(host, name: "settings-first-open")
        NotificationCenter.default.post(name: .showAboutSettingsSurface, object: state)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        NotificationCenter.default.post(name: .showSettingsSurface, object: state)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try assertSettingsViewport(in: host)
        for size in [NSSize(width: 900, height: 560), NSSize(width: 1280, height: 780), NSSize(width: 1800, height: 1068), NSSize(width: 900, height: 560)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            // Native controls must follow the detail column, including after a
            // wide window is shrunk again. Checking only the scroll view's frame
            // misses grouped Forms whose cards keep their intrinsic width.
            assertControlsFollowWidth(in: host)
            try assertSettingsViewport(in: host)
            try saveSnapshot(host, name: "settings-\(Int(size.width))")
        }
        XCTAssertGreaterThan(host.bounds.width, 0)
        XCTAssertLessThanOrEqual(window.contentMinSize.width, 1280)
    }

    @MainActor
    private func clickSettingsEntry(in host: NSView, window: NSWindow) throws {
        try click(NSPoint(x: 50, y: host.isFlipped ? host.bounds.maxY - 24 : 24), in: host, window: window)
    }

    @MainActor
    private func click(_ point: NSPoint, in host: NSView, window: NSWindow) throws {
        let location = host.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // Queue mouse-up before mouse-down in case a native button tracks it synchronously.
        let down = try event(.leftMouseDown)
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        window.sendEvent(down)
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                    inMode: .default, dequeue: true) { window.sendEvent(up) }
    }

    @MainActor
    func testClickingAnOpenSettingsTabAfterTerminalInputRetainsTheBatchEditor() throws {
        let state = AppState()
        state.preparePerformanceFixtureForTesting(count: 3)
        // Exercise real input responders and PTYs without connecting to a remote host.
        for runtime in state.runtimes.values {
            runtime.reconnect(launchConfiguration: .init(executable: "/bin/cat", arguments: [], environment: []))
        }
        defer { state.terminateAllSessionsImmediately() }
        let controller = state.batchJobs.selected
        let script = String(repeating: "printf '中文脚本\\n'\n", count: 1800)
        controller.job.script.body = script
        let suite = "TermPilot.SettingsTabReturn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: RootView.batchSettingsFixture()
            .environmentObject(state).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let views = descendants(host)
        let editor = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.string == script })
        let tabBar = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first {
            $0.bounds.height > 0 && $0.bounds.height < 65 && $0.bounds.width > 500
        })
        let bar = tabBar.convert(tabBar.bounds, to: host)
        let sidebar = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first {
            let rect = $0.convert($0.bounds, to: host)
            return abs(rect.minX - host.bounds.minX) <= 1 && rect.width < host.bounds.width / 2 && rect.height > 100
        })
        let tabStart = max(bar.minX, sidebar.convert(sidebar.bounds, to: host).maxX)
        try saveSnapshot(host, name: "tab-return-initial")
        let selection = NSRange(location: 5, length: 2)
        editor.setSelectedRange(selection)
        for iteration in 0..<20 {
            // Leave the batch editor's input context active when selecting a
            // workspace: disabling it during SwiftUI layout used to hang here.
            XCTAssertTrue(window.makeFirstResponder(editor))
            XCTAssertTrue(window.firstResponder === editor)
            let workspaceIndex = iteration % 2
            try click(NSPoint(x: tabStart + 220 + CGFloat(workspaceIndex) * 176, y: bar.midY), in: host, window: window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            if iteration == 0 { try saveSnapshot(host, name: "tab-return-workspace") }
            XCTAssertEqual(state.activeWorkspaceID, state.workspaces[workspaceIndex].id)
            XCTAssertFalse(editor.isEditable)
            let session = try XCTUnwrap(state.activeWorkspace?.focusedSessionID)
            let runtime = try XCTUnwrap(state.runtimes[session])
            XCTAssertEqual(runtime.lifecycle, .connected)
            let terminal = runtime.view()
            XCTAssertTrue(terminal.window === window)
            XCTAssertFalse(terminal.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(window.makeFirstResponder(terminal))
            XCTAssertTrue(window.firstResponder === terminal)
            terminal.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))

            try click(NSPoint(x: tabStart + 50, y: bar.midY), in: host, window: window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            XCTAssertFalse(window.firstResponder === terminal)
            XCTAssertTrue(terminal.window == nil || terminal.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(editor.window === window && editor.isEditable)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.string, script)
            XCTAssertEqual(controller.job.script.body, script)
            if iteration == 0 { try saveSnapshot(host, name: "tab-return-settings") }
        }
    }

    @MainActor
    private func assertSettingsViewport(in host: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let views = descendants(host)
        let stepper = try XCTUnwrap(views.compactMap { $0 as? NSStepper }.first, file: file, line: line)
        let scroll = try XCTUnwrap(stepper.enclosingScrollView, file: file, line: line)
        let frame = scroll.convert(scroll.bounds, to: host)
        let hostList = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first { candidate in
            let rect = candidate.convert(candidate.bounds, to: host)
            return abs(rect.minX - host.bounds.minX) <= 1 && rect.width < host.bounds.width / 2 && rect.height > 100
        }, file: file, line: line)
        let hostListFrame = hostList.convert(hostList.bounds, to: host)
        // The host list ends where the settings sidebar begins. The section must
        // leave room for the full 156-point sidebar and reach the window's right edge.
        XCTAssertGreaterThanOrEqual(frame.minX - hostListFrame.maxX, 156, file: file, line: line)
        XCTAssertEqual(frame.maxX, host.bounds.maxX, accuracy: 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, host.bounds.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, host.bounds.maxY + 1, file: file, line: line)
    }

    @MainActor
    func testGeneralSettingsCardsFitCompactAndWideWidths() throws {
        let suite = "TermPilot.SettingsWidthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: SettingsGeneralView()
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, scheme))
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 900),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.orderFront(nil)
            for width in [360, 640, 1360, 360] {
                window.setContentSize(NSSize(width: width, height: 900))
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                assertControlsFollowWidth(in: host)
                try saveSnapshot(host, name: "general-\(scheme)-\(width)")
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertLessThanOrEqual(document.bounds.width, scroll.bounds.width + 1)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                assertControlsFollowWidth(in: host)
                try saveSnapshot(host, name: "general-\(scheme)-\(width)-bottom")
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
    }

    @MainActor
    private func assertControlsFollowWidth(in host: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let controls = descendants(host).filter { $0 is NSStepper || $0 is NSSwitch }
        XCTAssertGreaterThanOrEqual(controls.count, 4, file: file, line: line)
        for control in controls {
            let frame = control.convert(control.bounds, to: host)
            let trailingInset = host.bounds.maxX - frame.maxX
            XCTAssertGreaterThanOrEqual(trailingInset, 16, file: file, line: line)
            XCTAssertLessThanOrEqual(trailingInset, 48, "Setting control does not follow the available width", file: file, line: line)
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor
    private func saveSnapshot(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TERMPILOT_SETTINGS_SNAPSHOTS"] else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
