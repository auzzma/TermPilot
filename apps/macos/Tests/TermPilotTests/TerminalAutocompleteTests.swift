import AppKit
import Foundation
import TermPilotDomain
@testable import TermPilotTerminal
@preconcurrency import SwiftTerm
import XCTest

@MainActor
final class TerminalAutocompleteTests: XCTestCase {
    func testPopupKeepsHorizontalAnchorWhileCursorMovesAndWraps() throws {
        try withAutocompleteOverlay { overlay, terminal, caret, popup in
            caret.frame = CGRect(x: 120, y: 400, width: 10, height: 20)
            let presentation = popupPresentation()
            overlay.update(presentation)
            let initialFrame = popup.frame
            XCTAssertEqual(initialFrame.minX, 120)

            caret.frame.origin.x = 300
            overlay.update(presentation)
            XCTAssertEqual(popup.frame.origin, initialFrame.origin)

            // A wrapped line changes both cursor coordinates; only Y follows.
            caret.frame.origin = CGPoint(x: 0, y: 380)
            overlay.updateLayout()
            XCTAssertEqual(popup.frame.minX, initialFrame.minX)
            XCTAssertEqual(popup.frame.minY, initialFrame.minY - 20)

            // Near the bottom the popup still flips above the cursor.
            caret.frame.origin = CGPoint(x: 30, y: 8)
            overlay.updateLayout()
            XCTAssertEqual(popup.frame.minX, initialFrame.minX)
            XCTAssertEqual(popup.frame.minY, caret.frame.maxY + 6)
            XCTAssertLessThanOrEqual(popup.frame.maxY, terminal.bounds.height - 8)
        }
    }

    func testPopupReanchorsAfterDismissalOrTerminalIsHidden() throws {
        try withAutocompleteOverlay { overlay, terminal, caret, popup in
            caret.frame = CGRect(x: 120, y: 400, width: 10, height: 20)
            overlay.update(popupPresentation())
            overlay.update(.empty)
            XCTAssertTrue(popup.isHidden)
            caret.frame.origin.x = 300
            overlay.update(popupPresentation())
            XCTAssertEqual(popup.frame.minX, 300)

            terminal.isHidden = true
            overlay.updateLayout()
            XCTAssertTrue(popup.isHidden)
            terminal.isHidden = false
            caret.frame.origin.x = 80
            overlay.updateLayout()
            XCTAssertFalse(popup.isHidden)
            XCTAssertEqual(popup.frame.minX, 80)
        }
    }

    func testPopupContentGrowthKeepsAnchorAndWindowResizeKeepsListInBounds() throws {
        try withAutocompleteOverlay { overlay, terminal, caret, popup in
            caret.frame = CGRect(x: 500, y: 400, width: 10, height: 20)
            overlay.update(popupPresentation())
            let initialX = popup.frame.minX
            var expanded = popupPresentation()
            expanded.suggestions[0].displayText = String(repeating: "long-command ", count: 8)
            expanded.suggestions[0].detail = "Command description"
            expanded.selectedIndex = 0
            overlay.update(expanded)
            XCTAssertEqual(popup.frame.minX, initialX)
            XCTAssertLessThanOrEqual(popup.frame.maxX, terminal.bounds.width - 8)
            popup.layoutSubtreeIfNeeded()
            for panel in popup.subviews where !panel.isHidden {
                XCTAssertLessThanOrEqual(panel.frame.maxX, popup.bounds.width)
            }
            overlay.update(popupPresentation())
            XCTAssertEqual(popup.frame.minX, initialX)

            terminal.setFrameSize(NSSize(width: 420, height: 600))
            overlay.updateLayout()
            XCTAssertGreaterThanOrEqual(popup.frame.minX, 8)
            XCTAssertGreaterThanOrEqual(popup.frame.width, 240)
            XCTAssertLessThanOrEqual(popup.frame.maxX, terminal.bounds.width - 8)
            let resizedX = popup.frame.minX
            caret.frame.origin.x = 10
            overlay.updateLayout()
            XCTAssertEqual(popup.frame.minX, resizedX)
        }
    }

    private func popupPresentation() -> TerminalAutocompletePresentation {
        TerminalAutocompletePresentation(
            suggestions: [.init(text: "git", displayText: "git", source: .command, score: 1)],
            showsPopupMenu: true
        )
    }

    private func withAutocompleteOverlay(
        _ body: (TerminalAutocompleteOverlayView, LocalProcessTerminalView, NSView, TerminalAutocompletePopupView) throws -> Void
    ) throws {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: terminal.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = terminal
        let overlay = TerminalAutocompleteOverlayView(terminalView: terminal)
        terminal.addSubview(overlay)
        defer {
            overlay.stopMonitoring()
            window.contentView = nil
        }
        let caret = try XCTUnwrap(terminal.subviews.first {
            String(describing: type(of: $0)).contains("CaretView")
        })
        let popup = try XCTUnwrap(overlay.subviews.compactMap { $0 as? TerminalAutocompletePopupView }.first)
        try body(overlay, terminal, caret, popup)
    }

    func testPopupAndDirectoryListsHaveFiniteFramesBeforeSizingAndAfterResizing() {
        let popup = TerminalAutocompletePopupView(frame: .zero)
        let suggestion = TerminalAutocompleteSuggestion(text: "cd docs", displayText: "docs", source: .path, score: 1, isDirectory: true)
        let panel = TerminalAutocompleteSubdirectoryPanel(entries: [.init(name: "src", kind: .directory)], selectedIndex: 0, directory: "docs")
        popup.update(suggestions: [suggestion], selectedIndex: 0, subdirectoryPanels: [panel], subdirectoryFocusLevel: 0)
        func check(_ view: NSView) {
            let frame = view.frame
            XCTAssertTrue([frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite), "\(type(of: view)): \(frame)")
            view.subviews.forEach(check)
        }
        for size in [NSSize.zero, NSSize(width: 5, height: 5), NSSize(width: 540, height: 120), .zero] {
            popup.setFrameSize(size)
            popup.needsLayout = true
            popup.layoutSubtreeIfNeeded()
            check(popup)
        }
    }

    func testThemePalettesMaintainReadableContrast() throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = TerminalAutocompleteThemePalette.colors(
            for: lightAppearance
        )
        let dark = TerminalAutocompleteThemePalette.colors(
            for: darkAppearance
        )

        for palette in [light, dark] {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(palette.primaryText, palette.background),
                4.5
            )
            XCTAssertGreaterThanOrEqual(
                contrastRatio(palette.secondaryText, palette.background),
                4.5
            )
            XCTAssertGreaterThanOrEqual(
                contrastRatio(palette.tertiaryText, palette.background),
                4.5
            )
            XCTAssertGreaterThanOrEqual(
                contrastRatio(
                    palette.primaryText,
                    palette.selectedBackground
                ),
                4.5
            )
            XCTAssertGreaterThanOrEqual(
                contrastRatio(palette.border, palette.background),
                1.5
            )
        }
        XCTAssertGreaterThan(
            contrastRatio(light.background, dark.background),
            10
        )
    }

    func testSettingsKeepPopupAndGhostTextMutuallyExclusive() {
        let settings = TerminalAutocompleteSettings(
            enabled: true,
            showsGhostText: true,
            showsPopupMenu: true
        )

        XCTAssertTrue(settings.normalized.enabled)
        XCTAssertTrue(settings.normalized.showsPopupMenu)
        XCTAssertFalse(settings.normalized.showsGhostText)
    }

    func testHistoryIsIsolatedByHostAndTracksFrequency() {
        let store = makeHistoryStore()
        store.record(command: "git status", hostKey: "first")
        store.record(command: "git status", hostKey: "first")
        store.record(command: "git stash", hostKey: "second")

        let first = store.suggestions(
            prefix: "git",
            hostKey: "first",
            limit: 8
        )
        let second = store.suggestions(
            prefix: "git",
            hostKey: "second",
            limit: 8
        )

        XCTAssertEqual(first.map(\.text), ["git status"])
        XCTAssertEqual(first.first?.frequency, 2)
        XCTAssertEqual(second.map(\.text), ["git stash"])
    }

    func testEngineCombinesCommandSubcommandAndLocalPathSuggestions() throws {
        let commandSuggestions = TerminalAutocompleteEngine.suggestions(
            for: "gi",
            history: [],
            maximum: 8,
            localCurrentDirectory: nil
        )
        let subcommandSuggestions = TerminalAutocompleteEngine.suggestions(
            for: "git ch",
            history: [],
            maximum: 8,
            localCurrentDirectory: nil
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("fixture.txt")
        try Data().write(to: file)
        let pathSuggestions = TerminalAutocompleteEngine.suggestions(
            for: "cat fi",
            history: [],
            maximum: 8,
            localCurrentDirectory: directory.path
        )

        XCTAssertTrue(
            commandSuggestions.contains(where: {
                $0.text == "git" && $0.source == .command
            })
        )
        XCTAssertTrue(
            subcommandSuggestions.contains(where: {
                $0.text == "git checkout"
            })
        )
        XCTAssertTrue(
            pathSuggestions.contains(where: {
                $0.text == "cat fixture.txt" && $0.source == .path
            })
        )
    }

    func testPopupNavigationPreviewsAndTabPassesThrough() async {
        let store = makeHistoryStore()
        let descriptor = makeSSHDescriptor()
        let hostKey = try! XCTUnwrap(descriptor.hostID).uuidString
        store.record(command: "git status", hostKey: hostKey)
        let controller = TerminalAutocompleteController(
            descriptor: descriptor,
            historyStore: store
        )
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: false,
                showsPopupMenu: true,
                debounceMilliseconds: 0
            )
        )
        var writes: [String] = []
        var replacedInput = ""
        controller.onWrite = { writes.append($0) }
        controller.onInputLineReplace = { replacedInput = $0 }

        XCTAssertFalse(
            controller.process(
                bytes: Array("g".utf8),
                renderedLine: "$ "
            )
        )
        await allowSuggestionTaskToRun()
        XCTAssertTrue(controller.presentation.popupVisible)

        XCTAssertTrue(
            controller.process(
                bytes: [0x1b, 0x5b, 0x42],
                renderedLine: "$ g"
            )
        )
        XCTAssertEqual(controller.presentation.selectedIndex, 0)
        XCTAssertEqual(writes.last, "\u{15}git status")
        XCTAssertEqual(replacedInput, "git status")

        XCTAssertFalse(
            controller.process(bytes: [0x09], renderedLine: "$ git status")
        )
        XCTAssertFalse(controller.presentation.popupVisible)
    }

    func testDeletingAllInputClosesPopupAndCancelsSuggestions() async {
        let store = makeHistoryStore()
        let descriptor = makeSSHDescriptor()
        let hostKey = try! XCTUnwrap(descriptor.hostID).uuidString
        store.record(command: "git status", hostKey: hostKey)
        let controller = TerminalAutocompleteController(
            descriptor: descriptor,
            historyStore: store
        )
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: false,
                showsPopupMenu: true,
                debounceMilliseconds: 0
            )
        )

        _ = controller.process(
            bytes: Array("g".utf8),
            renderedLine: "$ "
        )
        await allowSuggestionTaskToRun()
        XCTAssertTrue(controller.presentation.popupVisible)

        _ = controller.process(
            bytes: [0x7f],
            renderedLine: "$ g"
        )
        XCTAssertTrue(controller.typedInput.isEmpty)
        XCTAssertEqual(controller.presentation, .empty)

        await allowSuggestionTaskToRun()
        XCTAssertFalse(controller.presentation.popupVisible)
    }

    func testRightArrowAcceptsGhostText() async {
        let store = makeHistoryStore()
        let descriptor = makeSSHDescriptor()
        let hostKey = try! XCTUnwrap(descriptor.hostID).uuidString
        store.record(command: "git status", hostKey: hostKey)
        let controller = TerminalAutocompleteController(
            descriptor: descriptor,
            historyStore: store
        )
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: true,
                showsPopupMenu: false,
                debounceMilliseconds: 0
            )
        )
        var writes: [String] = []
        var replacedInput = ""
        controller.onWrite = { writes.append($0) }
        controller.onInputLineReplace = { replacedInput = $0 }

        _ = controller.process(
            bytes: Array("g".utf8),
            renderedLine: "$ "
        )
        await allowSuggestionTaskToRun()

        XCTAssertEqual(controller.presentation.ghostText, "it status")
        XCTAssertFalse(controller.presentation.popupVisible)
        XCTAssertTrue(
            controller.process(
                bytes: [0x1b, 0x5b, 0x43],
                renderedLine: "$ g"
            )
        )
        XCTAssertEqual(writes, ["it status"])
        XCTAssertEqual(controller.typedInput, "git status")
        XCTAssertEqual(replacedInput, "git status")
    }

    func testGhostTextStaysAlignedWhileTyping() async {
        let store = makeHistoryStore()
        let descriptor = makeSSHDescriptor()
        let hostKey = try! XCTUnwrap(descriptor.hostID).uuidString
        store.record(command: "git status", hostKey: hostKey)
        let controller = TerminalAutocompleteController(
            descriptor: descriptor,
            historyStore: store
        )
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: true,
                showsPopupMenu: false,
                debounceMilliseconds: 100
            )
        )

        _ = controller.process(
            bytes: Array("g".utf8),
            renderedLine: "$ "
        )
        await waitForGhostText("it status", in: controller)
        XCTAssertEqual(controller.presentation.ghostText, "it status")

        _ = controller.process(
            bytes: Array("i".utf8),
            renderedLine: "$ g"
        )
        XCTAssertEqual(controller.presentation.ghostText, "t status")
    }

    func testNonPromptInputDoesNotShowSuggestions() async {
        let store = makeHistoryStore()
        let descriptor = makeSSHDescriptor()
        let hostKey = try! XCTUnwrap(descriptor.hostID).uuidString
        store.record(command: "git status", hostKey: hostKey)
        let controller = TerminalAutocompleteController(
            descriptor: descriptor,
            historyStore: store
        )
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: false,
                showsPopupMenu: true,
                debounceMilliseconds: 0
            )
        )

        _ = controller.process(
            bytes: Array("g".utf8),
            renderedLine: "Password:"
        )
        await allowSuggestionTaskToRun()

        XCTAssertFalse(controller.presentation.popupVisible)
        XCTAssertTrue(controller.presentation.ghostText.isEmpty)
    }

    func testDatabaseREPLPromptDoesNotShowSuggestions() async {
        let store = makeHistoryStore()
        let descriptor = makeSSHDescriptor()
        let hostKey = try! XCTUnwrap(descriptor.hostID).uuidString
        store.record(command: "git status", hostKey: hostKey)
        let controller = TerminalAutocompleteController(
            descriptor: descriptor,
            historyStore: store
        )
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: false,
                showsPopupMenu: true,
                debounceMilliseconds: 0
            )
        )

        _ = controller.process(
            bytes: Array("g".utf8),
            renderedLine: "mysql> "
        )
        await allowSuggestionTaskToRun()

        XCTAssertFalse(controller.presentation.popupVisible)
    }

    func testPromptDetectionToleratesDelayedRemoteEcho() async {
        let store = makeHistoryStore()
        let descriptor = makeSSHDescriptor()
        let hostKey = try! XCTUnwrap(descriptor.hostID).uuidString
        store.record(command: "git status", hostKey: hostKey)
        let controller = TerminalAutocompleteController(
            descriptor: descriptor,
            historyStore: store
        )
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: false,
                showsPopupMenu: true,
                debounceMilliseconds: 0
            )
        )

        _ = controller.process(
            bytes: Array("g".utf8),
            renderedLine: "$ delayed-echo"
        )
        await allowSuggestionTaskToRun()

        XCTAssertTrue(controller.presentation.popupVisible)
    }

    func testFigCatalogProvidesNestedSubcommandOptions() {
        let suggestions = TerminalAutocompleteEngine.suggestions(
            for: "git commit --a",
            history: [],
            maximum: 20,
            localCurrentDirectory: nil
        )

        XCTAssertTrue(
            suggestions.contains(where: {
                $0.text == "git commit --amend"
                    && $0.source == .option
            })
        )
    }

    func testRemotePathSuggestionsUseCurrentDirectoryProvider() async {
        let controller = TerminalAutocompleteController(
            descriptor: makeSSHDescriptor(),
            historyStore: makeHistoryStore()
        )
        let probe = TerminalAutocompleteDirectoryProbe()
        controller.remoteDirectoryProvider = {
            path,
            foldersOnly,
            filterPrefix,
            limit in
            await probe.entries(
                path: path,
                foldersOnly: foldersOnly,
                filterPrefix: filterPrefix,
                limit: limit
            )
        }
        controller.currentDirectory = { "/srv" }
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: false,
                showsPopupMenu: true,
                debounceMilliseconds: 0
            )
        )

        _ = controller.process(
            bytes: Array("cat fi".utf8),
            renderedLine: "$ "
        )
        await allowRemoteSuggestionTaskToRun()

        XCTAssertTrue(
            controller.presentation.suggestions.contains(where: {
                $0.text == "cat fixture.txt"
                    && $0.source == .path
            })
        )
        let request = await probe.lastRequest
        XCTAssertEqual(request?.path, "/srv/")
        XCTAssertEqual(request?.filterPrefix, "fi")
    }

    func testDirectorySuggestionOpensCascadingPanel() async {
        let controller = TerminalAutocompleteController(
            descriptor: makeSSHDescriptor(),
            historyStore: makeHistoryStore()
        )
        let probe = TerminalAutocompleteDirectoryProbe()
        controller.remoteDirectoryProvider = {
            path,
            foldersOnly,
            filterPrefix,
            limit in
            await probe.entries(
                path: path,
                foldersOnly: foldersOnly,
                filterPrefix: filterPrefix,
                limit: limit
            )
        }
        controller.currentDirectory = { "/srv" }
        controller.configure(
            TerminalAutocompleteSettings(
                enabled: true,
                showsGhostText: false,
                showsPopupMenu: true,
                debounceMilliseconds: 0
            )
        )

        _ = controller.process(
            bytes: Array("cd fo".utf8),
            renderedLine: "$ "
        )
        await allowRemoteSuggestionTaskToRun()
        XCTAssertTrue(
            controller.process(
                bytes: [0x1b, 0x5b, 0x42],
                renderedLine: "$ cd fo"
            )
        )
        await allowRemoteSuggestionTaskToRun()

        XCTAssertEqual(
            controller.presentation.subdirectoryPanels.first?
                .entries.first?.name,
            "child.txt"
        )
        XCTAssertTrue(
            controller.process(
                bytes: [0x1b, 0x5b, 0x43],
                renderedLine: "$ cd folder/"
            )
        )
        XCTAssertEqual(controller.presentation.subdirectoryFocusLevel, 0)
    }

    private func makeHistoryStore() -> TerminalAutocompleteHistoryStore {
        let suiteName = "TerminalAutocompleteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return TerminalAutocompleteHistoryStore(
            defaults: defaults,
            storageKey: "history"
        )
    }

    private func makeSSHDescriptor() -> SessionDescriptor {
        SessionDescriptor(
            kind: .ssh,
            title: "Test",
            hostID: UUID(),
            hostname: "host.example.invalid",
            port: 22,
            username: "root"
        )
    }

    private func allowSuggestionTaskToRun() async {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    private func allowRemoteSuggestionTaskToRun() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func waitForGhostText(
        _ expected: String,
        in controller: TerminalAutocompleteController,
        timeout: TimeInterval = 1
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.presentation.ghostText != expected,
              Date() < deadline
        {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func contrastRatio(
        _ first: NSColor,
        _ second: NSColor
    ) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return 0
        }
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(rgb.redComponent)
            + 0.7152 * linearized(rgb.greenComponent)
            + 0.0722 * linearized(rgb.blueComponent)
    }
}

private actor TerminalAutocompleteDirectoryProbe {
    struct Request: Sendable {
        var path: String
        var foldersOnly: Bool
        var filterPrefix: String
        var limit: Int
    }

    private(set) var lastRequest: Request?

    func entries(
        path: String,
        foldersOnly: Bool,
        filterPrefix: String,
        limit: Int
    ) -> [TerminalAutocompleteDirectoryEntry] {
        lastRequest = Request(
            path: path,
            foldersOnly: foldersOnly,
            filterPrefix: filterPrefix,
            limit: limit
        )
        if path == "/srv/folder/" {
            return [
                TerminalAutocompleteDirectoryEntry(
                    name: "child.txt",
                    kind: .file
                ),
            ]
        }
        return [
            TerminalAutocompleteDirectoryEntry(
                name: "fixture.txt",
                kind: .file
            ),
            TerminalAutocompleteDirectoryEntry(
                name: "folder",
                kind: .directory
            ),
        ]
    }
}
