import Foundation
import TermPilotDomain
import TermPilotRemote
@testable import TermPilotTerminal
import TermPilotTestSupport
import XCTest

final class ConnectionLogTests: XCTestCase {
    @MainActor
    func testRuntimeStartsInConnectingStateAndLogsDisplayWait() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        XCTAssertEqual(runtime.lifecycle, .connecting)
        runtime.startIfDisplayed()

        let messages = runtime.connectionLog.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("Session queued"))
        XCTAssertTrue(messages.contains("Waiting for terminal surface"))
    }

    @MainActor
    func testConnectionLogsDoNotExposeAskPassSecret() throws {
        var host = Fixtures.host(authentication: .password)
        host.password = "fixture-login-value"
        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: host,
            bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
            runtime: SSH2BridgeRuntime(
                nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
            ),
            inheritedEnvironment: [:]
        )
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: host),
            launchConfiguration: launch,
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        runtime.startIfDisplayed()

        let messages = runtime.connectionLog.map(\.message).joined(separator: "\n")
        XCTAssertFalse(messages.contains("fixture-login-value"))
        XCTAssertFalse(messages.contains("TERMPILOT_SSH2_BRIDGE_CONFIG_B64"))
    }

    @MainActor
    func testSSH2BridgeOutputDrivesLifecycleAndConnectionLog() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: Fixtures.host()),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: Fixtures.host(),
                bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
                runtime: SSH2BridgeRuntime(
                    nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                    nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
                ),
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        XCTAssertTrue(runtime.isSSH2BridgeLaunchForTesting)

        runtime.processSSH2BridgeOutputForTesting(
            ssh2Control("init", "bridge starting")
        )
        XCTAssertEqual(runtime.lifecycle, .connecting)

        runtime.processSSH2BridgeOutputForTesting(
            ssh2Control("connected", "shell ready")
        )
        XCTAssertEqual(runtime.lifecycle, .connected)

        runtime.processSSH2BridgeOutputForTesting(
            ssh2Control("error", "auth failed")
        )
        XCTAssertEqual(runtime.lifecycle, .failed("auth failed"))

        let messages = runtime.connectionLog.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("ssh2 init: bridge starting"), messages)
        XCTAssertTrue(messages.contains("ssh2 connected: shell ready"), messages)
        XCTAssertTrue(messages.contains("ssh2 error: auth failed"), messages)
    }

    @MainActor
    func testSSH2BridgeTracksTerminalEffectiveUser() throws {
        let host = Fixtures.host()
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: host),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: host,
                bridgeScript: URL(
                    fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"
                ),
                runtime: SSH2BridgeRuntime(
                    nodeExecutable: URL(
                        fileURLWithPath: "/tmp/runtime/node/bin/node"
                    ),
                    nodeModulesDirectory: URL(
                        fileURLWithPath: "/tmp/runtime/node_modules"
                    )
                ),
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        XCTAssertEqual(runtime.currentUser, host.username)
        let display = runtime.processOutputForDisplayForTesting(
            ssh2Control("user", "root")
        )

        XCTAssertEqual(runtime.currentUser, "root")
        XCTAssertEqual(display, "")
    }

    @MainActor
    func testSSH2BridgeLatencyUpdatesWithoutRenderingOrLogging() throws {
        let host = Fixtures.host()
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: host),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: host,
                bridgeScript: URL(
                    fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"
                ),
                runtime: SSH2BridgeRuntime(
                    nodeExecutable: URL(
                        fileURLWithPath: "/tmp/runtime/node/bin/node"
                    ),
                    nodeModulesDirectory: URL(
                        fileURLWithPath: "/tmp/runtime/node_modules"
                    )
                ),
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        let display = runtime.processOutputForDisplayForTesting(
            ssh2Control("latency", "386")
        )

        XCTAssertEqual(display, "")
        XCTAssertEqual(runtime.latencyMilliseconds, 386)
        XCTAssertFalse(
            runtime.connectionLog.contains { $0.message.contains("latency") }
        )

        runtime.processSSH2BridgeOutputForTesting(
            ssh2Control("latency-unavailable", "unavailable")
        )
        XCTAssertNil(runtime.latencyMilliseconds)
    }

    func testLatencyQualityThresholds() {
        XCTAssertEqual(
            TerminalLatencyQuality.classify(milliseconds: 150),
            .good
        )
        XCTAssertEqual(
            TerminalLatencyQuality.classify(milliseconds: 151),
            .elevated
        )
        XCTAssertEqual(
            TerminalLatencyQuality.classify(milliseconds: 400),
            .elevated
        )
        XCTAssertEqual(
            TerminalLatencyQuality.classify(milliseconds: 401),
            .poor
        )
    }

    @MainActor
    func testSSH2BridgeHostKeyPromptDrivesRuntimePromptState() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: Fixtures.host()),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: Fixtures.host(),
                bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
                runtime: SSH2BridgeRuntime(
                    nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                    nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
                ),
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        runtime.processSSH2BridgeOutputForTesting(
            ssh2Control(
                "host-key-prompt",
                "SSH host key confirmation required {\"hostPattern\":\"host.example.invalid\",\"algorithm\":\"ssh-ed25519\",\"fingerprint\":\"SHA256:test\",\"hasHostPattern\":false}"
            )
        )

        XCTAssertEqual(
            runtime.hostKeyPrompt,
            SSHHostKeyPrompt(
                hostPattern: "host.example.invalid",
                algorithm: "ssh-ed25519",
                fingerprint: "SHA256:test",
                hasExistingHostPattern: false
            )
        )

        runtime.respondToHostKeyPrompt(accepted: false)

        XCTAssertNil(runtime.hostKeyPrompt)
        XCTAssertTrue(
            runtime.connectionLog.map(\.message)
                .contains("SSH host key rejected by user.")
        )
    }

    @MainActor
    func testSSH2BridgeLogsAreHiddenFromTerminalDisplay() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: Fixtures.host()),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: Fixtures.host(),
                bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
                runtime: SSH2BridgeRuntime(
                    nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                    nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
                ),
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        let firstDisplay = runtime.processOutputForDisplayForTesting(
            "\u{1E}[ssh2:init] bridge starting"
        )
        let secondDisplay = runtime.processOutputForDisplayForTesting(
            "\u{1F}root@host:~# "
        )

        XCTAssertEqual(firstDisplay + secondDisplay, "root@host:~# ")

        let messages = runtime.connectionLog.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("ssh2 init: bridge starting"), messages)
    }

    @MainActor
    func testSSH2BridgeImmediatelyDisplaysTrailingCRLF() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: Fixtures.host()),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: Fixtures.host(),
                bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
                runtime: SSH2BridgeRuntime(
                    nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                    nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
                ),
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        let line = "64 bytes from 1.1.1.1: time=0.5 ms\r\n"
        let firstDisplay = runtime.processOutputForDisplayForTesting(line)
        let secondDisplay = runtime.processOutputForDisplayForTesting(
            ssh2Control("latency", "386")
        )

        XCTAssertEqual(firstDisplay, line)
        XCTAssertEqual(secondDisplay, "")
        XCTAssertEqual(runtime.latencyMilliseconds, 386)
    }

    @MainActor
    func testSSH2BridgeCWDUpdatesCurrentDirectoryAndStaysHidden() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: Fixtures.host()),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: Fixtures.host(),
                bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
                runtime: SSH2BridgeRuntime(
                    nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                    nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
                ),
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        let display = runtime.processOutputForDisplayForTesting(
            ssh2Control("cwd", "/srv/app") + "root@host:/srv/app# "
        )

        XCTAssertEqual(runtime.currentDirectory, "/srv/app")
        XCTAssertEqual(display, "root@host:/srv/app# ")
        let messages = runtime.connectionLog.map(\.message).joined(separator: "\n")
        XCTAssertFalse(messages.contains("ssh2 cwd"))
    }

    @MainActor
    func testSSH2BridgeCapturesRemoteVersionWithoutDisplayingIt() throws {
        let runtime = TerminalSessionRuntime(
            descriptor: SessionDescriptor.ssh(host: Fixtures.host()),
            launchConfiguration: try SSH2BridgeTransport.launchConfiguration(
                host: Fixtures.host(),
                bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
                runtime: SSH2BridgeRuntime(
                    nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                    nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
                ),
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        let display = runtime.processOutputForDisplayForTesting(
            ssh2Control(
                "remote-version",
                "SSH-2.0-HUAWEI-VRP"
            ) + "root> "
        )

        XCTAssertEqual(runtime.remoteServerVersion, "SSH-2.0-HUAWEI-VRP")
        XCTAssertEqual(display, "root> ")
        XCTAssertFalse(
            runtime.connectionLog.map(\.message)
                .contains(where: { $0.contains("remote-version") })
        )
    }

    @MainActor
    func testSurfaceIdentitySeparatesClonedSessionsWithSameGeneration() throws {
        let first = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )
        let second = TerminalSessionRuntime(
            descriptor: SessionDescriptor.local(shell: "/bin/zsh"),
            launchConfiguration: LocalShellLaunch.configuration(
                shell: "/bin/zsh",
                inheritedEnvironment: [:]
            ),
            registry: TerminalSessionRegistry(),
            startOnDisplay: true
        )

        XCTAssertEqual(first.generation, second.generation)
        XCTAssertNotEqual(first.surfaceIdentity, second.surfaceIdentity)

        let previous = first.surfaceIdentity
        first.reconnect()
        XCTAssertNotEqual(first.surfaceIdentity, previous)
    }
}

private func ssh2Control(_ status: String, _ message: String) -> String {
    "\u{1E}[ssh2:\(status)] \(message)\u{1F}"
}
