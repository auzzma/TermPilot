@testable import TermPilotApp
import TermPilotDomain
import XCTest

final class TmuxManagementTests: XCTestCase {
    func testSessionCommandsValidateAndQuoteUserInput() throws {
        XCTAssertEqual(
            TmuxManagement.newSessionCommand(name: "dev"),
            "tmux new-session -d -s 'dev'"
        )
        XCTAssertEqual(
            TmuxManagement.newSessionCommand(name: nil),
            "tmux new-session -d"
        )
        XCTAssertEqual(
            TmuxManagement.newSessionCommand(name: "   "),
            "tmux new-session -d"
        )
        // Injection characters are stripped before quoting.
        XCTAssertEqual(
            TmuxManagement.newSessionCommand(name: "a; rm -rf /"),
            "tmux new-session -d -s 'arm-rf'"
        )
        // A name that sanitizes to nothing is rejected.
        XCTAssertNil(TmuxManagement.newSessionCommand(name: "@@@"))

        XCTAssertEqual(
            TmuxManagement.killSessionCommand(name: "dev"),
            "tmux kill-session -t 'dev'"
        )
        XCTAssertEqual(
            TmuxManagement.attachCommand(name: "dev"),
            "tmux attach-session -t 'dev'"
        )
        XCTAssertEqual(
            TmuxManagement.renameSessionCommand(
                current: "old",
                newName: "new"
            ),
            "tmux rename-session -t 'old' 'new'"
        )
        XCTAssertEqual(
            TmuxManagement.renameSessionCommand(
                current: "old",
                newName: "api; rm"
            ),
            "tmux rename-session -t 'old' 'apirm'"
        )
        XCTAssertNil(
            TmuxManagement.renameSessionCommand(
                current: "old",
                newName: "@@@"
            )
        )
    }

    func testSessionTargetsRejectControlCharactersAndQuoteQuotes() throws {
        XCTAssertNil(TmuxManagement.killSessionCommand(name: "dev\nrm"))
        XCTAssertNil(TmuxManagement.attachCommand(name: "   "))
        // Existing names keep their exact value but are shell-quoted so a
        // single quote cannot break out of the argument.
        XCTAssertEqual(
            TmuxManagement.killSessionCommand(name: "my'session"),
            "tmux kill-session -t 'my'\"'\"'session'"
        )
    }

    func testParseSessionsReadsFormattedOutput() throws {
        let output = """
        dev\t3\t1\t1700000000\t1700000500
        work\t1\t0\t\t
        """

        let sessions = TmuxManagement.parseSessions(output)

        XCTAssertEqual(sessions.count, 2)

        let dev = try XCTUnwrap(sessions.first { $0.name == "dev" })
        XCTAssertEqual(dev.windows, 3)
        XCTAssertTrue(dev.attached)
        XCTAssertEqual(
            dev.created,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            dev.lastActivity,
            Date(timeIntervalSince1970: 1_700_000_500)
        )

        let work = try XCTUnwrap(sessions.first { $0.name == "work" })
        XCTAssertEqual(work.windows, 1)
        XCTAssertFalse(work.attached)
        XCTAssertNil(work.created)
        XCTAssertNil(work.lastActivity)
    }

    func testParseSessionsSkipsMalformedLines() {
        let output = """
        onlyname
        \t2\t1
        good\t4\t0
        """

        let sessions = TmuxManagement.parseSessions(output)

        XCTAssertEqual(sessions.map(\.name), ["good"])
        XCTAssertEqual(sessions.first?.windows, 4)
    }

    func testMissingBinaryDetection() {
        XCTAssertTrue(
            TmuxManagement.indicatesMissingBinary(stderr: "", code: 127)
        )
        XCTAssertTrue(
            TmuxManagement.indicatesMissingBinary(
                stderr: "bash: tmux: command not found",
                code: 1
            )
        )
        // A running server with no sessions still exits non-zero, but that
        // is not a missing-binary condition.
        XCTAssertFalse(
            TmuxManagement.indicatesMissingBinary(
                stderr: "no server running on /tmp/tmux-501/default",
                code: 1
            )
        )
        XCTAssertFalse(
            TmuxManagement.indicatesMissingBinary(stderr: "", code: 0)
        )
    }

    func testWindowCommandsAndParsing() throws {
        XCTAssertEqual(
            TmuxManagement.listWindowsCommand(session: "dev"),
            "tmux list-windows -t 'dev' -F "
                + "'#{window_index}\t#{window_name}\t#{window_active}\t#{window_panes}' "
                + "2>/dev/null"
        )
        XCTAssertNil(TmuxManagement.listWindowsCommand(session: "  "))

        let output = """
        0\teditor\t1\t2
        1\tlogs\t0\t1
        bad-line
        """
        let windows = TmuxManagement.parseWindows(output, session: "dev")
        XCTAssertEqual(windows.count, 2)

        let editor = try XCTUnwrap(windows.first)
        XCTAssertEqual(editor.index, 0)
        XCTAssertEqual(editor.name, "editor")
        XCTAssertTrue(editor.active)
        XCTAssertEqual(editor.panes, 2)
        XCTAssertEqual(editor.session, "dev")
        XCTAssertEqual(editor.target, "dev:0")

        XCTAssertFalse(windows[1].active)
    }

    func testSendKeysCommandQuotesAndAppendsEnter() throws {
        let command = try XCTUnwrap(
            TmuxManagement.sendKeysCommand(
                target: "dev",
                keys: "git pull && make"
            )
        )
        XCTAssertEqual(
            command,
            "tmux send-keys -t 'dev' -l 'git pull && make'"
                + " && tmux send-keys -t 'dev' Enter"
        )
        // A single quote in the payload is escaped, not able to break out.
        let quoted = try XCTUnwrap(
            TmuxManagement.sendKeysCommand(
                target: "dev",
                keys: "echo 'hi'"
            )
        )
        XCTAssertTrue(quoted.contains("-l 'echo '\"'\"'hi'\"'\"''"))
        // Empty payloads and control characters are rejected.
        XCTAssertNil(TmuxManagement.sendKeysCommand(target: "dev", keys: "   "))
        XCTAssertNil(
            TmuxManagement.sendKeysCommand(target: "dev", keys: "ls\nrm")
        )
    }

    func testCapturePaneClampsHistoryDepth() throws {
        XCTAssertEqual(
            TmuxManagement.capturePaneCommand(target: "dev", lines: 200),
            "tmux capture-pane -p -t 'dev' -S -200 2>/dev/null"
        )
        XCTAssertEqual(
            TmuxManagement.capturePaneCommand(target: "dev", lines: 0),
            "tmux capture-pane -p -t 'dev' -S -1 2>/dev/null"
        )
        XCTAssertEqual(
            TmuxManagement.capturePaneCommand(target: "dev", lines: 999_999),
            "tmux capture-pane -p -t 'dev' -S -5000 2>/dev/null"
        )
        XCTAssertNil(TmuxManagement.capturePaneCommand(target: "  "))
    }

    func testKillServerAndAttachTakeover() {
        XCTAssertEqual(TmuxManagement.killServerCommand, "tmux kill-server")
        XCTAssertEqual(
            TmuxManagement.attachCommand(name: "dev"),
            "tmux attach-session -t 'dev'"
        )
        XCTAssertEqual(
            TmuxManagement.attachCommand(name: "dev", detachOthers: true),
            "tmux attach-session -d -t 'dev'"
        )
    }

    func testVersionParsing() {
        XCTAssertEqual(TmuxManagement.parseVersion("tmux 3.4"), "3.4")
        XCTAssertEqual(
            TmuxManagement.parseVersion("tmux next-3.5a\n"),
            "next-3.5a"
        )
        XCTAssertNil(TmuxManagement.parseVersion("command not found"))
        XCTAssertNil(TmuxManagement.parseVersion(""))
    }

    func testInstallHintMatchesDistroPackageManager() {
        XCTAssertEqual(TmuxManagement.installHint(for: .macos), "brew install tmux")
        XCTAssertEqual(
            TmuxManagement.installHint(for: .ubuntu),
            "sudo apt install tmux"
        )
        XCTAssertEqual(
            TmuxManagement.installHint(for: .alpine),
            "sudo apk add tmux"
        )
        XCTAssertEqual(
            TmuxManagement.installHint(for: .fedora),
            "sudo dnf install tmux"
        )
        XCTAssertEqual(
            TmuxManagement.installHint(for: .arch),
            "sudo pacman -S tmux"
        )
        // Unknown distros fall back to the most common package manager.
        XCTAssertEqual(
            TmuxManagement.installHint(for: nil),
            "sudo apt install tmux"
        )
    }
}
