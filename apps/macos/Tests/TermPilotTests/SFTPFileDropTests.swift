import AppKit
import CryptoKit
import SwiftUI
@testable import TermPilotApp
import TermPilotDomain
import TermPilotRemote
import TermPilotTestSupport
@testable import TermPilotTerminal
import XCTest

@MainActor
final class SFTPFileDropTests: XCTestCase {
    func testForegroundTerminalKeepsPathPasteAndRejectsHiddenOrDetachedDrops() async throws {
        let runtime = TerminalSessionRuntime(descriptor: .local(shell: "/bin/cat"),
            launchConfiguration: ProcessLaunchConfiguration(executable: "/bin/cat", arguments: [],
                environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8"], currentDirectory: "/tmp"),
            registry: TerminalSessionRegistry())
        defer { runtime.terminate() }
        let browser = NSHostingView(rootView: TerminalSurface(runtime: runtime, isActive: true))
        let window = makeWindow(browser)
        defer { window.contentView = nil; window.close() }
        browser.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let container = try XCTUnwrap(terminals(browser).first)
        let terminal = runtime.view()
        terminal.resize(cols: 120, rows: 24)
        for (index, receiver) in [container as NSView, terminal as NSView].enumerated() {
            let url = URL(fileURLWithPath: "/tmp/中文 it's here-\(index).txt")
            let drag = FileDragFixture(urls: [url])
            XCTAssertEqual(receiver.draggingEntered(drag), .copy)
            XCTAssertTrue(receiver.prepareForDragOperation(drag))
            XCTAssertTrue(receiver.performDragOperation(drag))
            let expected = TerminalDroppedFileFormatter.input(forFileURLs: [url])
            try await waitUntil {
                String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                    .replacingOccurrences(of: "\0", with: "").contains(expected)
            }
        }
        let drag = FileDragFixture(urls: [URL(fileURLWithPath: "/tmp/rejected.txt")])
        browser.rootView = TerminalSurface(runtime: runtime, isActive: false)
        try await Task.sleep(for: .milliseconds(100))
        for receiver in [container as NSView, terminal as NSView] {
            XCTAssertFalse(receiver.registeredDraggedTypes.contains(.fileURL))
            XCTAssertFalse(receiver.performDragOperation(drag))
        }
        browser.rootView = TerminalSurface(runtime: runtime, isActive: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(container.draggingEntered(drag), .copy)
        XCTAssertEqual(terminal.draggingEntered(drag), .copy)
        window.contentView = nil
        for receiver in [container as NSView, terminal as NSView] {
            XCTAssertFalse(receiver.registeredDraggedTypes.contains(.fileURL))
            XCTAssertFalse(receiver.performDragOperation(drag))
        }
    }

    func testNestedTerminalTabsAndSplitsFollowWorkspaceVisibility() async throws {
        let state = AppState()
        await state.openLocalShell()
        let grouped = try XCTUnwrap(state.activeWorkspace)
        let first = grouped.focusedSessionID
        let opened = await state.openTerminalTab(from: first, in: grouped.id)
        let second = try XCTUnwrap(opened)
        await state.openLocalShell()
        let other = try XCTUnwrap(state.activeWorkspace)
        for runtime in state.runtimes.values {
            runtime.reconnect(launchConfiguration: ProcessLaunchConfiguration(
                executable: "/usr/bin/true", arguments: [], environment: [], currentDirectory: "/tmp"))
        }
        defer { state.terminateAllSessionsImmediately() }
        let browser = NSHostingView(rootView: RootView(startsAIRuntime: false).environmentObject(state)
            .frame(minWidth: 900, minHeight: 560))
        let window = makeWindow(browser, width: 1280, height: 780)
        defer { window.contentView = nil; window.close() }
        func assertActive(_ ids: Set<UUID>) async throws {
            browser.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let expected = ids.compactMap { state.runtimes[$0]?.view() }
            let views = terminals(browser)
            XCTAssertEqual(views.count, 3)
            for view in views {
                let active = expected.contains { $0 === view.terminalView }
                XCTAssertEqual(view.isHidden, !active)
                XCTAssertEqual(view.registeredDraggedTypes.contains(.fileURL), active)
                XCTAssertEqual(view.terminalView.registeredDraggedTypes.contains(.fileURL), active)
            }
        }
        for selected in [first, second, first] {
            state.activeWorkspaceID = grouped.id
            state.selectTerminalTab(sessionID: selected, workspaceID: grouped.id)
            try await assertActive([selected])
        }
        state.activeWorkspaceID = other.id
        try await assertActive([other.focusedSessionID])
        let split = await state.splitTerminalTab(sessionID: second, workspaceID: grouped.id,
            nextTo: first, axis: .vertical, placement: .after)
        XCTAssertTrue(split)
        try await assertActive([first, second])
        state.activeWorkspaceID = other.id
        try await assertActive([other.focusedSessionID])
        state.activeWorkspaceID = grouped.id
        try await assertActive([first, second])
        NotificationCenter.default.post(name: .showSettingsSurface, object: state)
        try await assertActive([])
    }

    func testBackgroundWorkspacesCannotAcceptFileDrops() async throws {
        let state = AppState()
        state.preparePerformanceFixtureForTesting(count: 2)
        for runtime in state.runtimes.values { runtime.reconnect() }
        defer { state.terminateAllSessionsImmediately() }
        let suite = "TermPilot.DropRouting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = NSHostingView(rootView: RootView(startsAIRuntime: false)
            .environmentObject(state).defaultAppStorage(defaults)
            .frame(minWidth: 900, minHeight: 560))
        let window = makeWindow(browser, width: 1280, height: 780)
        defer { window.contentView = nil; window.close() }
        let drag = FileDragFixture(urls: [URL(fileURLWithPath: "/tmp/background-drop.txt")])
        for workspace in state.workspaces + state.workspaces.reversed() {
            state.activeWorkspaceID = workspace.id
            browser.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let expected = try XCTUnwrap(state.runtimes[workspace.focusedSessionID]).view()
            let views = terminals(browser)
            XCTAssertEqual(views.count, 2)
            for view in views {
                let active = view.terminalView === expected
                XCTAssertEqual(view.isHidden, !active, "A background terminal must be natively hidden")
                XCTAssertEqual(view.registeredDraggedTypes.contains(.fileURL), active)
                XCTAssertEqual(view.terminalView.registeredDraggedTypes.contains(.fileURL), active)
                if !active {
                    XCTAssertEqual(view.draggingEntered(drag), [])
                    XCTAssertEqual(view.terminalView.draggingEntered(drag), [])
                    XCTAssertFalse(view.performDragOperation(drag))
                    XCTAssertFalse(view.terminalView.performDragOperation(drag))
                }
            }
        }
    }

    func testAcceptedDropRendersHighlightInHostedBrowser() async throws {
        let model = SFTPBrowserModel(host: Fixtures.host(), dataSource: .local,
            initialLocalDirectory: FileManager.default.temporaryDirectory.path)
        let browser = NSHostingView(rootView: SFTPBrowserView(model: model, presentation: .remoteSidebar)
            .environmentObject(AppState())
            .environment(\.colorScheme, .light)
            .background(Color.white))
        let window = makeWindow(browser)
        defer { window.close(); model.close() }
        browser.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let view = try XCTUnwrap(destination(browser))
        func sample(_ name: String) throws -> NSColor {
            browser.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(browser.bitmapImageRepForCachingDisplay(in: browser.bounds))
            browser.cacheDisplay(in: browser.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["TERMPILOT_SFTP_DROP_SNAPSHOTS"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4,
                y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        }
        let before = try sample("before")
        let drag = FileDragFixture(urls: [URL(fileURLWithPath: "/tmp/a.txt")])
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertTrue(model.isRemoteDropTargeted)
        try await Task.sleep(for: .milliseconds(200))
        let during = try sample("during")
        XCTAssertGreaterThan(abs(during.redComponent - before.redComponent)
            + abs(during.greenComponent - before.greenComponent)
            + abs(during.blueComponent - before.blueComponent), 0.02,
            "Accepting a file must visibly highlight the hosted SFTP list")
        view.draggingExited(drag)
        try await Task.sleep(for: .milliseconds(200))
        let after = try sample("after")
        XCTAssertEqual(after.redComponent, before.redComponent, accuracy: 0.01)
        XCTAssertEqual(after.greenComponent, before.greenComponent, accuracy: 0.01)
        XCTAssertEqual(after.blueComponent, before.blueComponent, accuracy: 0.01)
    }

    func testDropRoutingWithCompletedTransfers() async throws {
        let state = AppState()
        state.recordFileTransfer(FileTransferRecord(kind: .upload, name: "done.txt",
            sourcePath: "", destinationPath: "", totalBytes: 1, status: .succeeded))
        for sidebarWidth in [CGFloat(350), 500] {
            let host = NSHostingView(rootView: HStack(spacing: 0) {
                Color.gray
                fixtureContent(list: true).frame(width: sidebarWidth)
            }
            .environmentObject(state))
            let window = makeWindow(host)
            defer { window.close() }
            window.setContentSize(NSSize(width: 1000, height: 600))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let view = try XCTUnwrap(destination(host))
            let drag = FileDragFixture(urls: [URL(fileURLWithPath: "/tmp/a.txt")])
            for y in stride(from: CGFloat(10), to: view.bounds.height, by: 20) {
                let point = view.convert(NSPoint(x: view.bounds.midX, y: y), to: host)
                var receiver = host.hitTest(point)
                while let current = receiver,
                      drag.draggingPasteboard.availableType(from: current.registeredDraggedTypes) == nil {
                    receiver = current.superview
                }
                XCTAssertTrue(receiver === view, "Transfer history intercepts file drop at \(point): \(String(describing: receiver))")
            }
        }
    }

    func testNativeRegistrationSurvivesContentUpdatesAndRejectsInactiveViews() async throws {
        let host = NSHostingView(rootView: fixtureContent(list: true))
        let window = makeWindow(host)
        defer { window.close() }
        for list in [true, false, true] {
            host.rootView = fixtureContent(list: list)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let view = try XCTUnwrap(destination(host))
            XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
            XCTAssertGreaterThan(view.bounds.height, 100)
            let drag = FileDragFixture(urls: [URL(fileURLWithPath: "/tmp/a.txt")])
            XCTAssertEqual(view.draggingEntered(drag), .copy)
            host.isHidden = true
            XCTAssertEqual(view.draggingUpdated(drag), [])
            XCTAssertFalse(view.performDragOperation(drag))
            host.isHidden = false
            XCTAssertEqual(view.draggingEntered(drag), .copy)
            view.isEnabled = false
            XCTAssertFalse(view.registeredDraggedTypes.contains(.fileURL))
            XCTAssertFalse(view.prepareForDragOperation(drag))
        }
        let view = try XCTUnwrap(destination(host))
        window.contentView = nil
        XCTAssertFalse(view.registeredDraggedTypes.contains(.fileURL))
    }

    func testFinderDropDeliversMultipleFilesAndClearsHighlight() {
        let view = SFTPFileDropView()
        let window = makeWindow(view)
        defer { window.close() }
        view.isEnabled = true
        var highlights: [Bool] = []
        var drops: [[URL]] = []
        view.onTargeted = { highlights.append($0) }
        view.onDrop = { drops.append($0); return true }
        let urls = ["/private/tmp/中文 文档.txt", "/private/tmp/Folder"].map { URL(fileURLWithPath: $0) }
        let drag = FileDragFixture(urls: urls + [urls[0]])
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertEqual(view.draggingUpdated(drag), .copy)
        XCTAssertTrue(view.prepareForDragOperation(drag))
        XCTAssertTrue(view.performDragOperation(drag))
        view.draggingEnded(drag)
        XCTAssertEqual(drops, [urls])
        XCTAssertEqual(highlights, [true, false])
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        view.draggingExited(drag)
        XCTAssertEqual(highlights, [true, false, true, false])
        drag.draggingSourceOperationMask = .move
        XCTAssertFalse(view.performDragOperation(drag))
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.writeObjects([NSURL(string: "https://example.com/file.txt")!])
        drag.draggingSourceOperationMask = .copy
        XCTAssertEqual(view.draggingEntered(drag), [])
        XCTAssertFalse(view.performDragOperation(drag))
        XCTAssertEqual(drops.count, 1)
    }

    func testNativeDropUploadsViaExistingQueueAndKeepsConflictPrompt() async throws {
        guard let engine = ProcessInfo.processInfo.environment["TERMPILOT_TEST_ENGINE"] else {
            throw XCTSkip("Set TERMPILOT_TEST_ENGINE for local SSH/SFTP integration")
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let server = Process(), input = Pipe(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["node", root.appendingPathComponent("tests/node/native-worker.test.cjs").path, "--fixture"]
        server.standardInput = input; server.standardOutput = output
        try server.run()
        defer { try? input.fileHandleForWriting.close(); server.waitUntilExit() }
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.availableData) as? [String: Any])
        let directory = URL(fileURLWithPath: try XCTUnwrap(info["directory"] as? String))
        let connectionID = UUID()
        let broker = Process(), brokerInput = Pipe()
        broker.executableURL = URL(fileURLWithPath: engine)
        broker.arguments = ["ssh-broker"]
        broker.standardInput = brokerInput
        broker.standardOutput = FileHandle.nullDevice
        broker.standardError = FileHandle.nullDevice
        try broker.run()
        defer { broker.terminate(); broker.waitUntilExit() }
        try brokerInput.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: [
            "hostname": "127.0.0.1", "port": try XCTUnwrap(info["port"] as? Int),
            "username": "fixture", "password": "fixture-password", "authentication": "password",
            "autoAcceptHostKeys": true, "knownHostsFile": directory.appendingPathComponent("known_hosts").path,
            "connectionID": connectionID.uuidString,
        ]) + Data([10]))
        try brokerInput.fileHandleForWriting.close()
        let hash = SHA256.hash(data: Data(connectionID.uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        let socketPath = "/tmp/TermPilot-\(getuid())/\(hash.prefix(32)).sock"
        try await waitUntil { FileManager.default.fileExists(atPath: socketPath) }
        var sshHost = Fixtures.host(hostname: "127.0.0.1", authentication: .password)
        sshHost.port = try XCTUnwrap(info["port"] as? Int)
        sshHost.username = "fixture"; sshHost.password = "fixture-password"
        let client = try SSH2SFTPBridgeClient(host: sshHost, sourceConnectionID: connectionID,
            runtime: SSH2BridgeRuntime(executable: URL(fileURLWithPath: engine)))
        let model = SFTPBrowserModel(host: sshHost)
        defer { model.close() }
        try await model.connectForTesting(client: client)
        let state = AppState()
        let browser = NSHostingView(rootView: SFTPBrowserView(model: model, presentation: .remoteSidebar, closesOnDisappear: false)
            .environmentObject(state).background(Color(nsColor: .windowBackgroundColor)))
        let window = makeWindow(browser)
        defer { window.close() }
        browser.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let view = try XCTUnwrap(destination(browser))
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
        // Match every type offered by the drag, including URL/text accepted by
        // native controls, rather than looking only for an exact .fileURL registration.
        let routingDrag = FileDragFixture(urls: [URL(fileURLWithPath: "/tmp/routing.txt")])
        for y in stride(from: CGFloat(10), to: view.bounds.height, by: 20) {
            for x in stride(from: CGFloat(10), to: view.bounds.width, by: 20) {
                let point = view.convert(NSPoint(x: x, y: y), to: browser)
                var receiver = browser.hitTest(point)
                while let current = receiver,
                      routingDrag.draggingPasteboard.availableType(from: current.registeredDraggedTypes) == nil {
                    receiver = current.superview
                }
                XCTAssertTrue(receiver === view, "A child view must not swallow Finder file drops at \(point): \(String(describing: receiver))")
            }
        }
        if let path = ProcessInfo.processInfo.environment["TERMPILOT_SFTP_DROP_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(browser.bitmapImageRepForCachingDisplay(in: browser.bounds))
            browser.cacheDisplay(in: browser.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path))
        }
        let local = directory.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let urls = [local.appendingPathComponent("拖入 文档.txt"), local.appendingPathComponent("empty.txt")]
        let contents = [Data("中文文件上传\n".utf8), Data()]
        for (url, data) in zip(urls, contents) { try data.write(to: url) }
        let drag = FileDragFixture(urls: urls)
        XCTAssertTrue(view.performDragOperation(drag))
        XCTAssertEqual(state.fileTransfers.count, 2)
        model.remotePathText = "/another-directory"
        try await waitUntil { state.fileTransfers.allSatisfy { !$0.isUnfinished } }
        XCTAssertTrue(state.fileTransfers.allSatisfy { $0.status == .succeeded }, "\(state.fileTransfers.map(\.status))")
        for (url, data) in zip(urls, contents) {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("remote").appendingPathComponent(url.lastPathComponent)), data)
        }
        model.remotePathText = "/"
        try Data("changed".utf8).write(to: urls[0])
        XCTAssertTrue(view.performDragOperation(FileDragFixture(urls: [urls[0]])))
        try await waitUntil { model.pendingOverwrite != nil }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("remote").appendingPathComponent(urls[0].lastPathComponent)), contents[0])
        let conflictID = try XCTUnwrap(model.pendingOverwrite?.transferID)
        state.controlFileTransfer(conflictID, action: .cancel)
        XCTAssertNil(model.pendingOverwrite)
        XCTAssertEqual(state.fileTransfers.first { $0.id == conflictID }?.status, .cancelled)
    }

    private func makeWindow(_ view: NSView, width: CGFloat = 500, height: CGFloat = 400) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private func destination(_ parent: NSView) -> SFTPFileDropView? {
        if let view = parent as? SFTPFileDropView { return view }
        return parent.subviews.compactMap(destination).first
    }

    private func terminals(_ parent: NSView) -> [TerminalContentInsetView] {
        if let view = parent as? TerminalContentInsetView { return [view] }
        return parent.subviews.flatMap(terminals)
    }

    private func fixtureContent(list: Bool) -> some View {
        SFTPFileDropArea(isEnabled: true, onTargeted: { _ in }, onDrop: { _ in true }) {
            VStack {
                Text("Remote Files")
                if list { List(["a", "b"], id: \.self) { Text($0) } }
                else { ScrollView { Text("Tree") }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition())
        if !condition() { throw NSError(domain: "SFTPDropTestTimeout", code: 1) }
    }
}

@MainActor
private final class FileDragFixture: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(urls: [URL]) { super.init(); draggingPasteboard.writeObjects(urls.map { $0 as NSURL }) }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
