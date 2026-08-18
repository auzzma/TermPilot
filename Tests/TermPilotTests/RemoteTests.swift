import Foundation
import TermPilotDomain
import TermPilotRemote
import TermPilotTestSupport
import XCTest

final class RemoteTests: XCTestCase {
    func testBridgeEOFClosesClientBeforeNextRequest() async throws {
        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        guard let nodePath = pathDirectories
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("node") })
            .first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            })
        else {
            throw XCTSkip("Node runtime is unavailable.")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bridge = root.appendingPathComponent("bridge.cjs")
        let modules = root.appendingPathComponent(
            "node_modules",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modules,
            withIntermediateDirectories: true
        )
        try Data(
            """
            process.stdout.write('{"id":0,"event":"ready"}\\n');
            setTimeout(() => process.exit(0), 10);
            """.utf8
        ).write(to: bridge)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let client = try SSH2SFTPBridgeClient(
            host: Fixtures.host(),
            bridgeScript: bridge,
            runtime: SSH2BridgeRuntime(
                nodeExecutable: nodePath,
                nodeModulesDirectory: modules
            ),
            opensFileChannel: false,
            inheritedEnvironment: [:]
        )
        try await client.waitUntilReady()
        try await Task.sleep(for: .milliseconds(100))

        do {
            _ = try await client.exec(command: "id -un")
            XCTFail("Expected the closed bridge request to fail.")
        } catch let error as SSH2SFTPBridgeError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testSFTPCurrentDirectoryRequestCarriesSelectedSessionID() async throws {
        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        guard let nodePath = pathDirectories
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("node") })
            .first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            })
        else {
            throw XCTSkip("Node runtime is unavailable.")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bridge = root.appendingPathComponent("bridge.cjs")
        let modules = root.appendingPathComponent(
            "node_modules",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modules,
            withIntermediateDirectories: true
        )
        try Data(
            """
            const readline = require("readline");
            process.stdout.write('{"id":0,"event":"ready"}\\n');
            const input = readline.createInterface({
              input: process.stdin,
              crlfDelay: Infinity,
            });
            const config = JSON.parse(Buffer.from(
              process.env.TERMPILOT_SFTP_BRIDGE_CONFIG_B64,
              "base64",
            ).toString("utf8"));
            input.on("line", (line) => {
              const request = JSON.parse(line);
              const result = request.action === "terminalCWD"
                ? { path: request.sourceSessionID || "" }
                : request.action === "exec"
                  ? {
                      stdout: `${request.elevated}:${config.persistentElevation}:${config.elevationMethod}:${config.elevationPassword}`,
                      stderr: "",
                      code: 0,
                      signal: null,
                    }
                  : request.action === "upload"
                    ? {
                        bytesTransferred:
                          request.fileConcurrency * 1000000000
                          + request.chunkConcurrency * 10000000
                          + request.chunkSizeBytes,
                      }
                  : {};
              process.stdout.write(JSON.stringify({
                id: request.id,
                ok: true,
                result,
              }) + "\\n");
            });
            """.utf8
        ).write(to: bridge)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let client = try SSH2SFTPBridgeClient(
            host: Fixtures.host(),
            bridgeScript: bridge,
            runtime: SSH2BridgeRuntime(
                nodeExecutable: nodePath,
                nodeModulesDirectory: modules
            ),
            opensFileChannel: false,
            elevatesOperations: true,
            persistentElevation: true,
            elevationMethod: .su,
            elevationPassword: "fixture-elevation-value",
            inheritedEnvironment: [:]
        )
        try await client.waitUntilReady()
        let selectedSessionID = UUID()
        let path = try await client.terminalCurrentDirectory(
            sourceSessionID: selectedSessionID
        )
        let elevated = try await client.exec(
            command: "id -u",
            elevated: true
        )
        let transfer = try await client.upload(
            localURL: URL(fileURLWithPath: "/tmp/fixture.bin"),
            to: "/tmp/fixture.bin",
            overwrite: true,
            options: SFTPTransferOptions(
                fileConcurrency: 3,
                chunkConcurrency: 7,
                chunkSizeBytes: 512 * 1_024
            )
        )
        await client.close()

        XCTAssertEqual(path, selectedSessionID.uuidString)
        XCTAssertEqual(elevated.stdout, "true:true:su:fixture-elevation-value")
        XCTAssertEqual(transfer.bytesTransferred, 3_070_524_288)
    }

    func testSSH2BridgeLaunchUsesNodeHelperInsteadOfOpenSSH() throws {
        let host = Fixtures.host()
        let helper = URL(fileURLWithPath: "/Applications/TermPilot.app/Contents/Resources/ssh2-bridge/termpilot-ssh2-bridge.cjs")
        let runtime = SSH2BridgeRuntime(
            nodeExecutable: URL(fileURLWithPath: "/Applications/TermPilot.app/Contents/Resources/ssh2-bridge-runtime/node/bin/node"),
            nodeModulesDirectory: URL(fileURLWithPath: "/Applications/TermPilot.app/Contents/Resources/ssh2-bridge-runtime/node_modules")
        )

        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: host,
            bridgeScript: helper,
            runtime: runtime,
            inheritedEnvironment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(launch.executable, runtime.nodeExecutable.path)
        XCTAssertEqual(launch.arguments, [helper.path])
        XCTAssertFalse(launch.arguments.contains("/usr/bin/ssh"))
        XCTAssertTrue(
            launch.environment.contains {
                $0.hasPrefix("TERMPILOT_SSH2_BRIDGE_CONFIG_B64=")
            }
        )
        XCTAssertTrue(
            launch.environment.contains(
                "TERMPILOT_SSH2_NODE_MODULES=\(runtime.nodeModulesDirectory.path)"
            )
        )

        let config = try decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["hostname"] as? String, host.hostname)
        XCTAssertEqual(config["username"] as? String, host.username)
        XCTAssertEqual(config["authentication"] as? String, host.authentication.rawValue)
        XCTAssertNotNil(config["connectionID"] as? String)
    }

    func testSSH2BridgeLaunchCarriesConnectionIDForSharedChannels() throws {
        let connectionID = UUID()
        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: Fixtures.host(),
            bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
            runtime: SSH2BridgeRuntime(
                nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
            ),
            connectionID: connectionID,
            inheritedEnvironment: [:]
        )

        let config = try decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["connectionID"] as? String, connectionID.uuidString)
    }

    func testSSH2BridgeLaunchCarriesKnownHostsFile() throws {
        let knownHostsFile = URL(fileURLWithPath: "/tmp/termpilot-known-hosts")
        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: Fixtures.host(),
            bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
            runtime: SSH2BridgeRuntime(
                nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
            ),
            knownHostsFile: knownHostsFile,
            inheritedEnvironment: [:]
        )

        let config = try decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["knownHostsFile"] as? String, knownHostsFile.path)
    }

    func testSSH2BridgeLaunchCarriesAutoAcceptHostKeys() throws {
        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: Fixtures.host(),
            bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
            runtime: SSH2BridgeRuntime(
                nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
            ),
            autoAcceptHostKeys: true,
            inheritedEnvironment: [:]
        )

        let config = try decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["autoAcceptHostKeys"] as? Bool, true)
    }

    func testSSH2BridgeLaunchCarriesSavedPrivateKeyContent() throws {
        var host = Fixtures.host(authentication: .identityFile)
        host.identityFile = nil
        host.identityKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture-key-material"
        host.passphrase = "fixture-passphrase-value"
        host.certificate = "ssh-ed25519-cert-v01@openssh.com AAAA"

        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: host,
            bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
            runtime: SSH2BridgeRuntime(
                nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
            ),
            inheritedEnvironment: [:]
        )

        XCTAssertFalse(launch.arguments.joined(separator: " ").contains("fixture-key-material"))
        XCTAssertFalse(launch.environment.joined(separator: " ").contains("fixture-key-material"))

        let config = try decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["privateKey"] as? String, host.identityKey)
        XCTAssertEqual(config["passphrase"] as? String, host.passphrase)
        XCTAssertEqual(config["certificate"] as? String, host.certificate)
    }

    func testSSH2BridgePasswordIsNotPlacedInArgumentsOrPlainEnvironment() throws {
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

        XCTAssertFalse(launch.arguments.joined(separator: " ").contains("fixture-login-value"))
        XCTAssertFalse(launch.environment.joined(separator: " ").contains("fixture-login-value"))

        let config = try decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["password"] as? String, "fixture-login-value")
    }

    func testSSH2BridgeLaunchCarriesResolvedProxyConfiguration() throws {
        var host = Fixtures.host()
        host.proxyConfiguration = SSHProxyConfiguration(
            type: .socks5,
            host: "proxy.example.invalid",
            port: 1080,
            username: "proxy-user",
            password: "fixture-proxy-value"
        )

        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: host,
            bridgeScript: URL(fileURLWithPath: "/tmp/termpilot-ssh2-bridge.cjs"),
            runtime: SSH2BridgeRuntime(
                nodeExecutable: URL(fileURLWithPath: "/tmp/runtime/node/bin/node"),
                nodeModulesDirectory: URL(fileURLWithPath: "/tmp/runtime/node_modules")
            ),
            inheritedEnvironment: [:]
        )

        XCTAssertFalse(launch.arguments.joined().contains("fixture-proxy-value"))
        XCTAssertFalse(launch.environment.joined().contains("fixture-proxy-value"))
        let config = try decodedSSH2BridgeConfig(from: launch)
        let proxy = try XCTUnwrap(config["proxy"] as? [String: Any])
        XCTAssertEqual(proxy["type"] as? String, "socks5")
        XCTAssertEqual(proxy["host"] as? String, "proxy.example.invalid")
        XCTAssertEqual(proxy["port"] as? Int, 1080)
        XCTAssertEqual(proxy["username"] as? String, "proxy-user")
        XCTAssertEqual(proxy["password"] as? String, "fixture-proxy-value")
    }

    func testSSH2BridgeRuntimeLocatorFindsBundledRuntimeShape() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtime = root
            .appendingPathComponent(
                SSH2BridgeRuntimeLocator.bundledRuntimeDirectoryName,
                isDirectory: true
            )
        let node = runtime.appendingPathComponent("node/bin/node")
        let modules = runtime.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(
            at: node.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modules,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: node.path,
            contents: Data("#!/bin/sh\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: node.path
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let found = try XCTUnwrap(
            SSH2BridgeRuntimeLocator.bundledRuntime(in: root)
        )
        XCTAssertEqual(found.nodeExecutable, node)
        XCTAssertEqual(found.nodeModulesDirectory, modules)
    }

    func testOpenSSHArgumentsUseStrictHostKeyCheckingAndIsolatedKnownHosts() throws {
        let host = Fixtures.host()
        let knownHosts = URL(fileURLWithPath: "/tmp/termpilot-known-hosts")
        let helper = URL(fileURLWithPath: "/Applications/TermPilot.app/Contents/MacOS/TermPilot")

        let launch = try OpenSSHTransport.launchConfiguration(
            host: host,
            knownHostsFile: knownHosts,
            askPassExecutable: helper,
            askPassRequestDirectory: URL(fileURLWithPath: "/tmp/termpilot-askpass"),
            inheritedEnvironment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(launch.executable, "/usr/bin/ssh")
        XCTAssertTrue(launch.arguments.contains("StrictHostKeyChecking=ask"))
        XCTAssertTrue(
            launch.arguments.contains("UserKnownHostsFile=/tmp/termpilot-known-hosts")
        )
        XCTAssertTrue(launch.arguments.contains("ControlMaster=no"))
        XCTAssertFalse(launch.arguments.contains("ControlMaster=auto"))
        XCTAssertFalse(launch.arguments.contains("ControlPersist=10m"))
        XCTAssertFalse(launch.arguments.contains { $0.hasPrefix("ControlPath=") })
        XCTAssertTrue(launch.arguments.suffix(2).elementsEqual(["--", host.hostname]))
        XCTAssertTrue(
            launch.environment.contains(
                "SSH_ASKPASS=/Applications/TermPilot.app/Contents/MacOS/TermPilot"
            )
        )
        XCTAssertTrue(launch.environment.contains("TERMPILOT_ASKPASS_MODE=1"))
        XCTAssertTrue(
            launch.environment.contains(
                "TERMPILOT_ASKPASS_REQUEST_DIR=/tmp/termpilot-askpass"
            )
        )
    }

    func testPasswordIsEncodedForAskPassAndNeverPlacedInArguments() throws {
        var host = Fixtures.host(authentication: .password)
        host.password = "fixture-login-value"

        let launch = try OpenSSHTransport.launchConfiguration(
            host: host,
            knownHostsFile: URL(fileURLWithPath: "/tmp/known_hosts"),
            askPassExecutable: URL(fileURLWithPath: "/tmp/TermPilot"),
            inheritedEnvironment: [:]
        )
        let serializedArguments = launch.arguments.joined(separator: " ")
        let serializedEnvironment = launch.environment.joined(separator: " ")

        XCTAssertFalse(serializedArguments.contains("fixture-login-value"))
        XCTAssertFalse(serializedEnvironment.contains("fixture-login-value"))
        XCTAssertTrue(
            launch.environment.contains(
                "TERMPILOT_ASKPASS_SECRET_B64=Zml4dHVyZS1sb2dpbi12YWx1ZQ=="
            )
        )
        XCTAssertTrue(
            launch.arguments.contains(
                "PreferredAuthentications=password,keyboard-interactive"
            )
        )
    }

    func testIdentityAuthenticationUsesExplicitIdentityAndAgentUsesNoIdentity() throws {
        var identityHost = Fixtures.host(authentication: .identityFile)
        identityHost.identityFile = "/fixtures/identity/id_ed25519"
        identityHost.certificate = "/fixtures/identity/id_ed25519-cert.pub"
        let identityLaunch = try launch(identityHost)

        XCTAssertTrue(identityLaunch.arguments.contains("-i"))
        XCTAssertTrue(identityLaunch.arguments.contains("/fixtures/identity/id_ed25519"))
        XCTAssertTrue(identityLaunch.arguments.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(identityLaunch.arguments.contains("PreferredAuthentications=publickey"))
        XCTAssertTrue(identityLaunch.arguments.contains("PasswordAuthentication=no"))
        XCTAssertTrue(identityLaunch.arguments.contains("KbdInteractiveAuthentication=no"))
        XCTAssertTrue(
            identityLaunch.arguments.contains(
                "CertificateFile=/fixtures/identity/id_ed25519-cert.pub"
            )
        )

        let agentLaunch = try launch(Fixtures.host(authentication: .agent))
        XCTAssertFalse(agentLaunch.arguments.contains("-i"))
    }

    func testExitCodeClassification() {
        XCTAssertEqual(SSHExitCategory.classify(exitCode: 0), .clean)
        XCTAssertEqual(SSHExitCategory.classify(exitCode: 255), .connectionFailed)
        XCTAssertEqual(SSHExitCategory.classify(exitCode: 130), .cancelled)
        XCTAssertEqual(SSHExitCategory.classify(exitCode: nil), .unknown)
    }

    func testOpenSSHDisablesConnectionMultiplexingForEveryLaunch() throws {
        let host = Fixtures.host()

        let first = try launch(host)
        let second = try launch(host)

        XCTAssertTrue(first.arguments.contains("ControlMaster=no"))
        XCTAssertTrue(second.arguments.contains("ControlMaster=no"))
        XCTAssertFalse(first.arguments.contains { $0.hasPrefix("ControlPath=") })
        XCTAssertFalse(second.arguments.contains { $0.hasPrefix("ControlPath=") })
    }

    private func launch(
        _ host: TermPilotDomain.Host
    ) throws -> ProcessLaunchConfiguration {
        try OpenSSHTransport.launchConfiguration(
            host: host,
            knownHostsFile: URL(fileURLWithPath: "/tmp/known_hosts"),
            askPassExecutable: URL(fileURLWithPath: "/tmp/TermPilot"),
            inheritedEnvironment: [:]
        )
    }

    private func decodedSSH2BridgeConfig(
        from launch: ProcessLaunchConfiguration
    ) throws -> [String: Any] {
        let prefix = "TERMPILOT_SSH2_BRIDGE_CONFIG_B64="
        let encoded = try XCTUnwrap(
            launch.environment.first { $0.hasPrefix(prefix) }?.dropFirst(prefix.count)
        )
        let data = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
