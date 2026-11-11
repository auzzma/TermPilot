import AppKit
import SwiftTerm
import TermPilotDomain
@testable import TermPilotTerminal
import XCTest

final class TerminalCopyLinkTests: XCTestCase {
    @MainActor
    func testDraggingAcrossLinksNeverOpensThemWhenCommandIsPressedToCopy() throws {
        for explicit in [false, true] {
            for startsWithCommand in [false, true] {
                let view = makeView(explicit: explicit)
                var openedURLs: [URL] = []
                view.openTerminalLink = { openedURLs.append($0) }
                view.mouseDown(with: try mouseEvent(
                    .leftMouseDown, in: view,
                    modifiers: startsWithCommand ? .command : []
                ))
                view.mouseDragged(with: try mouseEvent(
                    .leftMouseDragged, in: view, x: 30
                ))
                view.mouseDragged(with: try mouseEvent(
                    .leftMouseDragged, in: view, x: 90
                ))
                let selection = try XCTUnwrap(view.getSelection())
                XCTAssertFalse(selection.isEmpty)

                view.mouseUp(with: try mouseEvent(
                    .leftMouseUp, in: view, x: 90, modifiers: .command
                ))

                XCTAssertTrue(openedURLs.isEmpty)
                XCTAssertEqual(view.getSelection(), selection)
            }
        }
    }

    @MainActor
    func testOnlyCompleteCommandSingleClickOpensLinks() throws {
        for explicit in [false, true] {
            let view = makeView(explicit: explicit)
            var openedURLs: [URL] = []
            view.openTerminalLink = { openedURLs.append($0) }

            // Releasing with Command alone must not activate a link.
            view.mouseUp(with: try mouseEvent(
                .leftMouseUp, in: view, modifiers: .command
            ))
            let cases: [(NSEvent.ModifierFlags, NSEvent.ModifierFlags, Int)] = [
                ([], [], 1),
                ([], .command, 1),
                (.command, [], 1),
                (.command, .command, 2),
                (.command, .command, 3),
                ([.command, .shift], [.command, .shift], 1),
            ]
            for (downModifiers, upModifiers, clickCount) in cases {
                view.mouseDown(with: try mouseEvent(
                    .leftMouseDown, in: view,
                    modifiers: downModifiers, clickCount: clickCount
                ))
                view.mouseUp(with: try mouseEvent(
                    .leftMouseUp, in: view,
                    modifiers: upModifiers, clickCount: clickCount
                ))
            }
            XCTAssertTrue(openedURLs.isEmpty)

            // A fresh click after a selection must still work.
            view.mouseDown(with: try mouseEvent(
                .leftMouseDown, in: view, modifiers: .command
            ))
            view.mouseUp(with: try mouseEvent(
                .leftMouseUp, in: view, modifiers: .command
            ))
            XCTAssertEqual(openedURLs.map(\.absoluteString), [Self.link])

            // The preceding click must not authorize later callbacks.
            view.requestOpenLink(source: view, link: Self.link, params: [:])
            XCTAssertEqual(openedURLs.count, 1)
        }
    }

    @MainActor
    func testCommandClickDoesNotSendShellPathsToWorkspace() throws {
        for link in ["/var/log/system.log", "./Sources/main.swift", "src/main.swift"] {
            let view = makeView(text: link)
            var openedURLs: [URL] = []
            view.openTerminalLink = { openedURLs.append($0) }
            XCTAssertEqual(
                view.getTerminal().link(
                    at: .screen(Position(col: 1, row: 0)),
                    mode: .explicitAndImplicit
                ),
                link
            )

            view.mouseDown(with: try mouseEvent(
                .leftMouseDown, in: view, modifiers: .command
            ))
            view.mouseUp(with: try mouseEvent(
                .leftMouseUp, in: view, modifiers: .command
            ))

            XCTAssertTrue(openedURLs.isEmpty)
        }
    }

    @MainActor
    func testCopyActionsPreservePlainTextWithoutOpeningLinks() throws {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved.setData(data, forType: type)
                }
            }
            return saved
        }
        defer {
            pasteboard.clearContents()
            if !savedItems.isEmpty {
                pasteboard.writeObjects(savedItems)
            }
        }

        let runtime = makeRuntime()
        let view = try XCTUnwrap(runtime.view() as? AutoStartingTerminalView)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.feed(text: "复制测试 \(Self.link) /var/log/system.log")
        view.selectAll()
        let selection = try XCTUnwrap(view.getSelection())
        var openedURLs: [URL] = []
        view.openTerminalLink = { openedURLs.append($0) }

        runtime.copySelection()
        XCTAssertEqual(pasteboard.string(forType: .string), selection)
        pasteboard.clearContents()
        XCTAssertTrue(NSApplication.shared.sendAction(
            #selector(TerminalView.copy(_:)), to: view, from: nil
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), selection)

        pasteboard.clearContents()
        let menu = try XCTUnwrap(view.menu(for: mouseEvent(.rightMouseDown, in: view)))
        let copyItem = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(copyItem.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(copyItem.action), to: copyItem.target, from: copyItem
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), selection)
        let plainTextTypes: Set<NSPasteboard.PasteboardType> = [
            .string, NSPasteboard.PasteboardType("NSStringPboardType"),
        ]
        XCTAssertTrue(Set(pasteboard.types ?? []).isSubset(of: plainTextTypes))
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testLinkURLRejectsInvalidAndRemoteFileTargets() throws {
        for link in ["", "/var/log/system.log", "../main.swift", "https://", "https:example.com",
                     "file://remote-server/var/log/system.log",
                     "file:///termpilot-missing-\(UUID().uuidString)"] {
            XCTAssertNil(terminalLinkURL(link), link)
        }
        for link in [Self.link, "mailto:hello@example.com", "ssh://user@example.com"] {
            XCTAssertEqual(terminalLinkURL(link)?.absoluteString, link)
        }
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("termpilot-link-\(UUID().uuidString).txt")
        try Data("test".utf8).write(to: localFile)
        defer { try? FileManager.default.removeItem(at: localFile) }
        XCTAssertEqual(terminalLinkURL(localFile.absoluteString), localFile)
    }

    private static let link = "https://example.com/terminal-copy-regression"

    @MainActor
    private func makeRuntime() -> TerminalSessionRuntime {
        TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh", inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: false
        )
    }

    @MainActor
    private func makeView(explicit: Bool = false, text: String? = nil) -> AutoStartingTerminalView {
        let view = makeRuntime().view() as! AutoStartingTerminalView
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        if explicit {
            view.feed(text: "\u{1B}]8;;\(Self.link)\u{7}terminal hyperlink text\u{1B}]8;;\u{7}")
        } else {
            view.feed(text: text ?? Self.link)
        }
        return view
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        in view: TerminalView,
        x: CGFloat = 1,
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: view.frame.height - 1),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }
}
