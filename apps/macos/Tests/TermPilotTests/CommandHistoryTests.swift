@testable import TermPilotApp
import TermPilotDomain
import XCTest

final class CommandHistoryTests: XCTestCase {
    func testBashHistoryParsesTimestampedMultilineCommands() throws {
        let entries = RemoteCommandHistoryParser.parseBash(
            """
            #1700000000
            echo first
            echo second
            #1700000100
            pwd
            """
        )

        XCTAssertEqual(entries.map(\.command), ["echo first\necho second", "pwd"])
        XCTAssertEqual(
            try XCTUnwrap(entries.first?.timestamp).timeIntervalSince1970,
            1_700_000_000,
            accuracy: 0.001
        )
    }

    func testZshHistoryParsesExtendedRecordsAndContinuations() throws {
        let entries = RemoteCommandHistoryParser.parseZsh(
            """
            : 1700000000:0;echo first\\
            echo second
            : 1700000100:2;pwd
            """
        )

        XCTAssertEqual(entries.map(\.command), ["echo first\necho second", "pwd"])
        XCTAssertEqual(
            try XCTUnwrap(entries.last?.timestamp).timeIntervalSince1970,
            1_700_000_100,
            accuracy: 0.001
        )
    }

    func testFishHistoryParsesEscapedCommandsAndTimestamp() throws {
        let entries = RemoteCommandHistoryParser.parseFish(
            """
            - cmd: echo first\\nsecond
              when: 1700000200
              paths:
                - /tmp
            """
        )

        XCTAssertEqual(entries.map(\.command), ["echo first\nsecond"])
        XCTAssertEqual(
            try XCTUnwrap(entries.first?.timestamp).timeIntervalSince1970,
            1_700_000_200,
            accuracy: 0.001
        )
    }

    func testRemoteHistorySelectsDetectedShellAndKeepsNewestUniqueCommands() {
        let entries = RemoteCommandHistoryParser.parse(
            """
            __TP_HISTORY_SHELL__zsh
            __TP_HISTORY_ZSH__
            : 1700000000:0;pwd
            : 1700000100:0;ls -la
            : 1700000200:0;pwd
            : 1700000300:0;echo __NCMCP_internal
            """
        )

        XCTAssertEqual(entries.map(\.command), ["pwd", "ls -la"])
        XCTAssertTrue(entries.allSatisfy { $0.source == .zsh })
    }

    func testHistoryUserFollowsRootAndFallsBackForUnknownUsers() {
        XCTAssertEqual(
            CommandHistoryModel.historyUsername(
                terminalUsername: "root",
                loginUsername: "pilot"
            ),
            "root"
        )
        XCTAssertEqual(
            CommandHistoryModel.historyUsername(
                terminalUsername: "postgres",
                loginUsername: "pilot"
            ),
            "pilot"
        )
        XCTAssertEqual(
            CommandHistoryModel.historyUsername(
                terminalUsername: nil,
                loginUsername: "pilot"
            ),
            "pilot"
        )
    }

    @MainActor
    func testLocalHistoryLoadsWithoutCreatingRemoteClient() async {
        let model = CommandHistoryModel(
            host: TermPilotDomain.Host(
                label: "Local Terminal",
                hostname: "localhost",
                username: NSUserName(),
                distro: .macos
            ),
            workspaceID: UUID(),
            sourceConnectionID: nil,
            sourceSessionID: nil,
            dataSource: .local(shell: "/bin/sh")
        )

        await model.refresh(using: AppState())

        XCTAssertNotNil(model.fetchedAt)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }
}
