import TermPilotDomain
import TermPilotRemote
@testable import TermPilotTerminal
import TermPilotTestSupport
import XCTest

final class PasswordPromptAssistTests: XCTestCase {
    func testDetectorArmsOnlyDirectSudoAndSuCommands() {
        XCTAssertEqual(
            PasswordPromptDetector.commandKind("sudo whoami"),
            .sudo
        )
        XCTAssertEqual(
            PasswordPromptDetector.commandKind("command su - root"),
            .su
        )
        XCTAssertNil(PasswordPromptDetector.commandKind("sum values"))
        XCTAssertNil(
            PasswordPromptDetector.commandKind(
                "echo '[sudo] password for alice:'"
            )
        )
    }

    func testDetectorExtractsRecalledCommandFromRenderedPromptLine() {
        XCTAssertEqual(
            PasswordPromptDetector.assistedCommand(
                in: "alice@example:~$ sudo whoami"
            ),
            "sudo whoami"
        )
        XCTAssertEqual(
            PasswordPromptDetector.assistedCommand(
                in: "~/project ❯ su - root"
            ),
            "su - root"
        )
        XCTAssertNil(
            PasswordPromptDetector.assistedCommand(
                in: "alice@example:~$ mysql -p"
            )
        )
    }

    func testDetectorRejectsConcealedAndChildProgramPrompts() {
        XCTAssertFalse(
            PasswordPromptDetector.isExplicitSudoPrompt(
                "\u{1B}[8m[sudo] password for alice: \u{1B}[0m"
            )
        )
        XCTAssertFalse(
            PasswordPromptDetector.isSudoScopedPasswordPrompt(
                "Enter password: "
            )
        )
        XCTAssertFalse(
            PasswordPromptDetector.isSuPasswordPrompt(
                "bob@host.example.invalid's password: "
            )
        )
    }

    func testDetectorAllowsRealAuthenticationRetryAfterFill() {
        var detector = PasswordPromptDetector()
        detector.arm(for: "su -")
        XCTAssertEqual(detector.observe(output: "Password: "), .su)

        detector.markFilled()

        XCTAssertEqual(
            detector.observe(
                output: "su: Authentication failure\r\nPassword: "
            ),
            .su
        )
    }

    @MainActor
    func testPickerRequestContainsLabelsButNeverPasswords() throws {
        let runtime = makeSSHRuntime()
        runtime.configurePasswordPromptAssist(
            mode: .picker,
            credentials: [
                PasswordPromptCredential(
                    id: "host",
                    label: "Production",
                    username: "alice",
                    password: "fixture-host-value",
                    isHostCredential: true
                ),
                PasswordPromptCredential(
                    id: "root",
                    label: "Root",
                    username: "root",
                    password: "fixture-elevation-value"
                ),
            ]
        )

        submit("su -", to: runtime)
        _ = runtime.processOutputForDisplayForTesting("Password: ")

        let request = try XCTUnwrap(runtime.passwordPromptRequest)
        XCTAssertEqual(request.presentation, .picker)
        XCTAssertEqual(request.items.map(\.label), ["Production", "Root"])
        let description = String(describing: request)
        XCTAssertFalse(description.contains("fixture-host-value"))
        XCTAssertFalse(description.contains("fixture-elevation-value"))
    }

    @MainActor
    func testArmedSudoUsesPickerAndIgnoresDatabasePrompt() throws {
        let runtime = makeSSHRuntime()
        runtime.configurePasswordPromptAssist(
            mode: .picker,
            credentials: [
                PasswordPromptCredential(
                    id: "host",
                    label: "Production",
                    username: "alice",
                    password: "fixture-host-value",
                    isHostCredential: true
                ),
                PasswordPromptCredential(
                    id: "database",
                    label: "Database",
                    username: "postgres",
                    password: "fixture-database-value"
                ),
            ]
        )

        submit("sudo mysql -p", to: runtime)
        _ = runtime.processOutputForDisplayForTesting("Enter password: ")
        XCTAssertNil(runtime.passwordPromptRequest)

        submit("sudo whoami", to: runtime)
        _ = runtime.processOutputForDisplayForTesting(
            "[sudo] password for alice: "
        )
        let request = try XCTUnwrap(runtime.passwordPromptRequest)
        XCTAssertEqual(request.presentation, .picker)
        XCTAssertEqual(request.items.map(\.id), ["host", "database"])
    }

    @MainActor
    func testUnarmedExplicitSudoPromptOnlyOffersHostPassword() throws {
        let runtime = makePickerRuntime()

        _ = runtime.processOutputForDisplayForTesting(
            "[sudo] password for alice: "
        )

        let request = try XCTUnwrap(runtime.passwordPromptRequest)
        XCTAssertEqual(request.presentation, .hint)
        XCTAssertEqual(request.items.map(\.id), ["host"])
    }

    @MainActor
    func testEnterConfirmsSelectionAndRealAuthRetryReopensPicker() throws {
        let runtime = makePickerRuntime()
        submit("su -", to: runtime)
        _ = runtime.processOutputForDisplayForTesting("Password: ")

        let forwarded = runtime.processUserInputForProcess([0x0d][...])

        XCTAssertEqual(forwarded, [])
        XCTAssertNil(runtime.passwordPromptRequest)

        _ = runtime.processOutputForDisplayForTesting(
            "su: Authentication failure\r\nPassword: "
        )
        XCTAssertNotNil(runtime.passwordPromptRequest)
    }

    @MainActor
    func testControlDThenRecalledSuStillShowsPicker() throws {
        let runtime = makePickerRuntime()
        submit("su -", to: runtime)
        _ = runtime.processOutputForDisplayForTesting("Password: ")
        runtime.selectPasswordPromptCredential(id: "host")

        _ = runtime.processUserInputForProcess([0x04][...])
        _ = runtime.processUserInputForProcess(
            [0x1b, 0x5b, 0x41][...]
        )
        _ = runtime.processUserInputForProcess(
            [0x0d][...],
            renderedLine: "alice@example:~$ su -"
        )
        _ = runtime.processOutputForDisplayForTesting("Password: ")

        let request = try XCTUnwrap(runtime.passwordPromptRequest)
        XCTAssertEqual(request.presentation, .picker)
    }

    @MainActor
    func testManualPasswordInputDismissesAssistAndPassesThrough() {
        let runtime = makePickerRuntime()
        submit("su -", to: runtime)
        _ = runtime.processOutputForDisplayForTesting("Password: ")

        let typed = runtime.processUserInputForProcess([0x73][...])
        let enter = runtime.processUserInputForProcess([0x0d][...])

        XCTAssertEqual(typed, [0x73])
        XCTAssertEqual(enter, [0x0d])
        XCTAssertNil(runtime.passwordPromptRequest)

        _ = runtime.processOutputForDisplayForTesting("Password: ")
        XCTAssertNil(runtime.passwordPromptRequest)
    }

    @MainActor
    func testPickerNavigationAndSoftDismissMatchOriginalInteraction() throws {
        let runtime = makePickerRuntime()
        submit("su -", to: runtime)
        _ = runtime.processOutputForDisplayForTesting("Password: ")

        let down = runtime.processUserInputForProcess(
            [0x1b, 0x4f, 0x42][...]
        )
        XCTAssertEqual(down, [])
        XCTAssertEqual(runtime.passwordPromptRequest?.selectedIndex, 1)

        let backspace = runtime.processUserInputForProcess([0x7f][...])
        XCTAssertEqual(backspace, [])
        XCTAssertNil(runtime.passwordPromptRequest)

        let reopen = runtime.processUserInputForProcess([0x1b][...])
        XCTAssertEqual(reopen, [])
        XCTAssertEqual(
            try XCTUnwrap(runtime.passwordPromptRequest).selectedIndex,
            1
        )
    }

    @MainActor
    func testModeOffNeverShowsCredentialUI() {
        let runtime = makeSSHRuntime()
        runtime.configurePasswordPromptAssist(
            mode: .off,
            credentials: [
                PasswordPromptCredential(
                    id: "host",
                    label: "Production",
                    username: "alice",
                    password: "fixture-host-value",
                    isHostCredential: true
                ),
            ]
        )

        submit("sudo whoami", to: runtime)
        _ = runtime.processOutputForDisplayForTesting(
            "[sudo] password for alice: "
        )

        XCTAssertNil(runtime.passwordPromptRequest)
    }

    @MainActor
    func testAutomaticPasswordIsOneShotThenRetriesUseNormalAssist() throws {
        let runtime = makePickerRuntime()
        runtime.sendText(
            "su - root -c 'docker logs abc123'\n",
            automaticPassword: "fixture-automatic-elevation-value"
        )

        _ = runtime.processOutputForDisplayForTesting("Password: ")
        XCTAssertNil(runtime.passwordPromptRequest)

        _ = runtime.processOutputForDisplayForTesting(
            "su: Authentication failure\r\nPassword: "
        )
        let request = try XCTUnwrap(runtime.passwordPromptRequest)
        XCTAssertEqual(request.presentation, .picker)
        XCTAssertFalse(
            String(describing: request)
                .contains("fixture-automatic-elevation-value")
        )
    }

    @MainActor
    private func makePickerRuntime() -> TerminalSessionRuntime {
        let runtime = makeSSHRuntime()
        runtime.configurePasswordPromptAssist(
            mode: .picker,
            credentials: [
                PasswordPromptCredential(
                    id: "host",
                    label: "Production",
                    username: "alice",
                    password: "fixture-host-value",
                    isHostCredential: true
                ),
                PasswordPromptCredential(
                    id: "root",
                    label: "Root",
                    username: "root",
                    password: "fixture-elevation-value"
                ),
            ]
        )
        return runtime
    }

    @MainActor
    private func makeSSHRuntime() -> TerminalSessionRuntime {
        let host = Fixtures.host()
        return TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: host),
            launchConfiguration: ProcessLaunchConfiguration(
                executable: "/usr/bin/true",
                arguments: [],
                environment: []
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: false
        )
    }

    @MainActor
    private func submit(
        _ command: String,
        to runtime: TerminalSessionRuntime
    ) {
        for byte in command.utf8 {
            _ = runtime.processUserInputForProcess([byte][...])
        }
        _ = runtime.processUserInputForProcess([0x0d][...])
    }
}
