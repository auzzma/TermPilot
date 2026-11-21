import AppKit
import Foundation
import TermPilotCore
import TermPilotDomain
import TermPilotRemote
import TermPilotTerminal
import XCTest

@MainActor
final class SavedScriptTerminalTests: XCTestCase {
    func testInsertWaitsAndRunUsesTheCurrentShell() async throws {
        try await withTerminal(shell: "/bin/zsh", arguments: ["-f", "-i"]) { runtime, directory in
            try await self.waitFor { runtime.acceptsSavedScriptInput && runtime.usesBracketedPaste }
            let output = directory.appendingPathComponent("result")
            try await self.send("echo 1 > result\necho 2 >> result\necho 3 >> result\n", "insert", to: runtime)
            try await self.waitFor {
                String(decoding: runtime.view().getTerminal().getBufferAsData(), as: UTF8.self).contains("echo 3")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            runtime.sendText("\r")
            try await self.waitFor { (try? String(contentsOf: output, encoding: .utf8)) == "1\n2\n3\n" }

            try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: false)
            try await self.waitFor { runtime.usesBracketedPaste }
            try await self.send("""
            cd sub
            saved='本次会话'
            for n in 1 2 3; do
              if [[ -n $n ]]; then echo "$n" >> sequence; fi
            done
            """, "run", to: runtime)
            let sub = directory.appendingPathComponent("sub")
            try await self.waitFor { (try? String(contentsOf: sub.appendingPathComponent("sequence"), encoding: .utf8)) == "1\n2\n3\n" }
            try await self.waitFor { runtime.usesBracketedPaste }
            runtime.sendText("echo \"$saved\" > inherited\\ marker\r")
            try await self.waitFor { (try? String(contentsOf: sub.appendingPathComponent("inherited marker"), encoding: .utf8)) == "本次会话\n" }
        }
    }

    func testStartupWaitsForFirstPromptBeforeSubmittingMultilineInput() async throws {
        try await withTerminal(shell: "/bin/sh", arguments: ["-c", "sleep 0.2; exec /bin/zsh -f -i"]) { runtime, directory in
            try await self.waitFor { runtime.acceptsSavedScriptInput }
            try await self.send("echo one > result\necho two >> result", "run", to: runtime, waitForPrompt: true)
            try await self.waitFor { (try? String(contentsOf: directory.appendingPathComponent("result"), encoding: .utf8)) == "one\ntwo\n" }
        }
    }

    func testPlainTerminalRejectsMultilineBeforeWritingAndStillRunsSingleCommands() async throws {
        try await withTerminal(shell: "/bin/sh", arguments: ["-c", "stty icanon -echo && touch ready && exec /bin/sh +o emacs +o vi -i"]) { runtime, directory in
            try await self.waitFor { FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) }
            XCTAssertFalse(runtime.usesBracketedPaste)
            do {
                try await self.send("echo first > partial\necho last >> partial", "run", to: runtime)
                XCTFail("Submitted multiple lines to a plain terminal")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Enable bracketed paste in the current shell to use this script.")
            }
            try await self.send("echo ok > result", "run", to: runtime)
            try await self.waitFor { (try? String(contentsOf: directory.appendingPathComponent("result"), encoding: .utf8)) == "ok\n" }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("partial").path))
        }
    }

    private func send(_ body: String, _ action: String, to runtime: TerminalSessionRuntime, waitForPrompt: Bool = false) async throws {
        let plan = try SharedCore.call(["method": "savedScriptPlan", "body": body, "action": action])
        try await runtime.sendSavedScriptInput(
            bracketed: try XCTUnwrap(plan["bracketedInput"] as? String),
            plain: plan["plainInput"] as? String, waitForPrompt: waitForPrompt
        )
    }

    private func withTerminal(shell: String, arguments: [String], perform: (TerminalSessionRuntime, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = TerminalSessionRuntime(
            descriptor: .local(shell: shell),
            launchConfiguration: ProcessLaunchConfiguration(
                executable: shell, arguments: arguments,
                environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "HISTFILE=/dev/null", "ENV=/dev/null", "HOME=\(directory.path)"],
                currentDirectory: directory.path
            ), registry: TerminalSessionRegistry()
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = runtime.view()
        defer { runtime.terminate(); window.contentView = nil }
        runtime.startIfDisplayed()
        try await perform(runtime, directory)
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try XCTUnwrap(condition() ? true : nil, "Timed out waiting for the local shell", file: file, line: line)
    }
}
