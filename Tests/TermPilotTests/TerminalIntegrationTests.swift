import AppKit
import Foundation
import SwiftTerm
import TermPilotDomain
@testable import TermPilotTerminal
import XCTest

final class TerminalIntegrationTests: XCTestCase {
    func testLocalShellDefaultsToUserHomeDirectory() {
        let launch = LocalShellLaunch.configuration(
            shell: "/bin/zsh",
            inheritedEnvironment: [:]
        )

        XCTAssertEqual(
            launch.currentDirectory,
            FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    func testDroppedFileInputQuotesPathsAndKeepsDirectorySlash() {
        let input = TerminalDroppedFileFormatter.input(
            forFileURLs: [
                URL(fileURLWithPath: "/fixtures/user/Documents/a file.txt"),
                URL(fileURLWithPath: "/fixtures/user/Projects/it's-here", isDirectory: true),
            ]
        )

        XCTAssertEqual(
            input,
            "'/fixtures/user/Documents/a file.txt' '/fixtures/user/Projects/it'\\''s-here/' "
        )
    }

    @MainActor
    func testTerminalContextMenuTracksSelectionAvailability() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: false
        )
        runtime.configureContextMenu(
            titles: TerminalContextMenuTitles(
                copy: "Copy Test",
                paste: "Paste Test",
                pasteSelectedText: "Paste Selection Test"
            )
        )
        let terminalView = runtime.view()
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        let emptyMenu = try XCTUnwrap(terminalView.menu(for: event))
        XCTAssertFalse(emptyMenu.allowsContextMenuPlugIns)
        if #available(macOS 15.2, *) {
            XCTAssertFalse(emptyMenu.automaticallyInsertsWritingToolsItems)
        }
        XCTAssertEqual(
            emptyMenu.items.map(\.title),
            ["Copy Test", "Paste Test", "Paste Selection Test"]
        )
        XCTAssertEqual(
            emptyMenu.items.map(\.isEnabled),
            [false, true, false]
        )
        emptyMenu.addItem(
            NSMenuItem(
                title: "AutoFill",
                action: nil,
                keyEquivalent: ""
            )
        )
        emptyMenu.delegate?.menuNeedsUpdate?(emptyMenu)
        XCTAssertEqual(
            emptyMenu.items.map(\.title),
            ["Copy Test", "Paste Test", "Paste Selection Test"]
        )

        terminalView.feed(text: "selected text")
        terminalView.selectAll()
        let selectedMenu = try XCTUnwrap(terminalView.menu(for: event))
        XCTAssertEqual(
            selectedMenu.items.map(\.isEnabled),
            [true, true, true]
        )
    }

    @MainActor
    func testStreamingOutputPreservesTerminalSelection() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: false
        )
        let terminalView = runtime.view()
        terminalView.feed(text: "selected text")
        terminalView.selectAll()
        let selection = try XCTUnwrap(terminalView.getSelection())

        let output = Array("\r\nping output".utf8)
        terminalView.dataReceived(slice: output[...])

        XCTAssertTrue(terminalView.selectionActive)
        XCTAssertTrue(
            terminalView.getSelection()?.contains(selection) == true
        )
        XCTAssertTrue(terminalView.allowMouseReporting)
    }

    @MainActor
    func testTerminalCursorAndSelectionColorsMatchOriginalTheme() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: false
        )
        let terminalView = runtime.view()

        assertColor(
            terminalView.caretColor,
            red: 88,
            green: 166,
            blue: 255
        )
        assertColor(
            terminalView.selectedTextBackgroundColor,
            red: 38,
            green: 79,
            blue: 120
        )
        assertColor(
            terminalView.selectedTextForegroundColor,
            red: 201,
            green: 209,
            blue: 217
        )
    }

    @MainActor
    func testTerminalCursorBlinksOnlyWhileFocused() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: false
        )
        let terminalView = runtime.view()
        let caretView = try XCTUnwrap(
            terminalView.subviews.first {
                String(describing: type(of: $0)).contains("CaretView")
            }
        )

        terminalView.hasFocus = false
        XCTAssertNil(
            caretView.layer?.animation(
                forKey: "termpilot.cursor-blink"
            )
        )
        XCTAssertEqual(caretView.layer?.opacity, 1)

        terminalView.hasFocus = true
        XCTAssertTrue(terminalView.hasFocus)
        let blinkAnimation = try XCTUnwrap(
            caretView.layer?.animation(
                forKey: "termpilot.cursor-blink"
            )
        )
        XCTAssertEqual(blinkAnimation.duration, 1.2)

        terminalView.hasFocus = false
        XCTAssertNil(
            caretView.layer?.animation(
                forKey: "termpilot.cursor-blink"
            )
        )
        XCTAssertEqual(caretView.layer?.opacity, 1)
    }

    @MainActor
    func testFocusRequestedBeforeDisplayRemainsPending() {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: false
        )
        _ = runtime.view()

        runtime.focus()

        XCTAssertTrue(runtime.hasPendingFocusRequest)
    }

    @MainActor
    func testTerminalLeadingInsetRoutesSelectionToFirstColumn() {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: false
        )
        let terminalView = runtime.view()
        let insetView = TerminalContentInsetView(
            terminalView: terminalView,
            leadingInset: 10
        )
        insetView.frame = NSRect(
            x: 0,
            y: 0,
            width: 200,
            height: 100
        )
        insetView.layout()

        XCTAssertEqual(terminalView.frame.minX, 10)
        XCTAssertIdentical(
            insetView.hitTest(NSPoint(x: 5, y: 50)),
            terminalView
        )
        XCTAssertEqual(
            terminalView.convert(
                NSPoint(x: 5, y: 50),
                from: insetView
            ).x,
            -5
        )
    }

    func testLocalPTYCapturesOrderedOutputAndExitCode() throws {
        let exited = expectation(description: "Local PTY process exited")
        var observedExitCode: Int32?
        let terminal = HeadlessTerminal { exitCode in
            observedExitCode = exitCode
            exited.fulfill()
        }

        terminal.process.startProcess(
            executable: "/bin/sh",
            args: ["-lc", "printf 'TERMPILOT_PTY_OK'"]
        )

        wait(for: [exited], timeout: 5)
        let deadline = Date().addingTimeInterval(1)
        var output = ""
        repeat {
            output = String(
                decoding: terminal.terminal.getBufferAsData(),
                as: UTF8.self
            )
            if output.contains("TERMPILOT_PTY_OK") {
                break
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(0.01)
            )
        } while Date() < deadline

        XCTAssertEqual(observedExitCode, 0)
        XCTAssertTrue(output.contains("TERMPILOT_PTY_OK"))
    }

    private func assertColor(
        _ color: NSColor,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let color = color.usingColorSpace(.sRGB) else {
            return XCTFail(
                "Expected an sRGB color.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            color.redComponent,
            red / 255,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            color.greenComponent,
            green / 255,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            color.blueComponent,
            blue / 255,
            accuracy: 0.001,
            file: file,
            line: line
        )
    }
}
