import Foundation
import TermPilotDomain
import TermPilotRemote
import TermPilotTestSupport
import XCTest

final class RemoteTests: XCTestCase {
    func testSFTPProgressDrainsWhileOtherConnectionsAreIdle() async throws {
        let node = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let node else { throw XCTSkip("Node test fixture is unavailable.") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPilot-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = directory.appendingPathComponent("bridge.cjs")
        try Data("""
        #!\(node.path)
        const { once } = require('node:events');
        const lines = require('node:readline').createInterface({ input: process.stdin });
        const deadline = setTimeout(() => process.exit(12), 15000);
        let configured = false;
        async function send(value) {
          if (!process.stdout.write(JSON.stringify(value) + '\\n'))
            await once(process.stdout, 'drain');
        }
        lines.on('line', async line => {
          const command = JSON.parse(line);
          if (!configured) { configured = true; await send({ id: 0, event: 'ready' }); return; }
          if (command.action === 'upload') {
            // More than a pipe's capacity: completion requires continuously
            // draining progress, even while other clients' stderr is silent.
            for (let i = 1; i <= 10000; i++)
              await send({ id: command.id, event: 'progress', transferred: i * 20972, total: 209720000 });
            await send({ id: command.id, ok: true, result: { bytesTransferred: 209720000 } });
          } else {
            await send({ id: command.id, ok: true, result: {} });
            if (command.action === 'close') { clearTimeout(deadline); process.exit(0); }
          }
        });
        """.utf8).write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
        var clients: [SSH2SFTPBridgeClient] = []
        do {
            for _ in 0..<8 {
                let client = try SSH2SFTPBridgeClient(
                    host: Fixtures.host(),
                    runtime: SSH2BridgeRuntime(executable: bridge),
                    inheritedEnvironment: [:]
                )
                clients.append(client)
                try await client.waitUntilReady()
            }
            let result = try await clients[0].upload(
                localURL: directory.appendingPathComponent("synthetic.bin"),
                to: "/synthetic.bin", overwrite: false,
                progress: { _ in }
            )
            XCTAssertEqual(result.bytesTransferred, 209720000)
        } catch {
            for client in clients { await client.close() }
            throw error
        }
        for client in clients { await client.close() }
    }

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
            #!\(nodePath.path)
            process.stdout.write('{"id":0,"event":"ready"}\\n');
            setTimeout(() => process.exit(0), 10);
            """.utf8
        ).write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let client = try SSH2SFTPBridgeClient(
            host: Fixtures.host(),
            runtime: SSH2BridgeRuntime(
                executable: bridge
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
            #!\(nodePath.path)
            const readline = require("readline");
            process.stdout.write('{"id":0,"event":"ready"}\\n');
            const input = readline.createInterface({
              input: process.stdin,
              crlfDelay: Infinity,
            });
            let config;
            input.on("line", (line) => {
              if (!config) { config = JSON.parse(line); return; }
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
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let client = try SSH2SFTPBridgeClient(
            host: Fixtures.host(),
            runtime: SSH2BridgeRuntime(
                executable: bridge
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

    func testSSHBridgeLaunchUsesRustAndPrivateConfigurationPipe() async throws {
        let host = Fixtures.host()
        let runtime = SSH2BridgeRuntime(
            executable: URL(fileURLWithPath: "/Applications/TermPilot.app/Contents/Resources/engine/termpilot-engine")
        )

        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: host,
            runtime: runtime,
            inheritedEnvironment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(launch.executable, runtime.executable.path)
        XCTAssertEqual(launch.arguments.count, 2)
        XCTAssertEqual(launch.arguments.first, "ssh-terminal")
        XCTAssertEqual(launch.arguments.last, launch.privateConfiguration?.path)
        XCTAssertFalse(launch.environment.contains { $0.hasPrefix("TERMPILOT_") })

        let config = try await decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["hostname"] as? String, host.hostname)
        XCTAssertEqual(config["username"] as? String, host.username)
        XCTAssertEqual(config["authentication"] as? String, host.authentication.rawValue)
        XCTAssertNotNil(config["connectionID"] as? String)
    }

    func testSSH2BridgeLaunchCarriesConnectionIDForSharedChannels() async throws {
        let connectionID = UUID()
        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: Fixtures.host(),
            runtime: SSH2BridgeRuntime(
                executable: URL(fileURLWithPath: "/tmp/runtime/termpilot-engine")
            ),
            connectionID: connectionID,
            inheritedEnvironment: [:]
        )

        let config = try await decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["connectionID"] as? String, connectionID.uuidString)
    }

    func testSSHReconnectGetsANewPrivatePipeAfterFirstLaunchConsumesIt() async throws {
        var launch = try SSH2BridgeTransport.launchConfiguration(
            host: Fixtures.host(),
            runtime: SSH2BridgeRuntime(executable: URL(fileURLWithPath: "/tmp/termpilot-engine")),
            inheritedEnvironment: [:]
        )
        launch = try launch.preparedForLaunch()
        let firstPath = try XCTUnwrap(launch.privateConfiguration).path
        let first = try await decodedSSH2BridgeConfig(from: launch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath))
        launch = try launch.preparedForLaunch()
        let secondPath = try XCTUnwrap(launch.privateConfiguration).path
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(launch.arguments.last, secondPath)
        let second = try await decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(first["connectionID"] as? String, second["connectionID"] as? String)
        XCTAssertEqual(first["hostname"] as? String, second["hostname"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondPath))
        XCTAssertFalse(launch.environment.contains { $0.hasPrefix("TERMPILOT_") })
    }

    func testCancelledPrivateConfigurationDeliveryRemovesUnusedPipe() async throws {
        let configuration = try PrivateEngineConfiguration(Data("{\"fixture\":true}".utf8))
        let sender = Task { try await configuration.send() }
        sender.cancel()
        do {
            try await sender.value
            XCTFail("Cancelled delivery should not wait for a reader")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.path))
    }

    func testSSH2BridgeLaunchCarriesKnownHostsFile() async throws {
        let knownHostsFile = URL(fileURLWithPath: "/tmp/termpilot-known-hosts")
        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: Fixtures.host(),
            runtime: SSH2BridgeRuntime(
                executable: URL(fileURLWithPath: "/tmp/runtime/termpilot-engine")
            ),
            knownHostsFile: knownHostsFile,
            inheritedEnvironment: [:]
        )

        let config = try await decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["knownHostsFile"] as? String, knownHostsFile.path)
    }

    func testSSH2BridgeLaunchCarriesAutoAcceptHostKeys() async throws {
        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: Fixtures.host(),
            runtime: SSH2BridgeRuntime(
                executable: URL(fileURLWithPath: "/tmp/runtime/termpilot-engine")
            ),
            autoAcceptHostKeys: true,
            inheritedEnvironment: [:]
        )

        let config = try await decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["autoAcceptHostKeys"] as? Bool, true)
    }

    func testSSH2BridgeLaunchCarriesSavedPrivateKeyContent() async throws {
        var host = Fixtures.host(authentication: .identityFile)
        host.identityFile = nil
        host.identityKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture-key-material"
        host.passphrase = "fixture-passphrase-value"
        host.certificate = "ssh-ed25519-cert-v01@openssh.com AAAA"

        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: host,
            runtime: SSH2BridgeRuntime(
                executable: URL(fileURLWithPath: "/tmp/runtime/termpilot-engine")
            ),
            inheritedEnvironment: [:]
        )

        XCTAssertFalse(launch.arguments.joined(separator: " ").contains("fixture-key-material"))
        XCTAssertFalse(launch.environment.joined(separator: " ").contains("fixture-key-material"))

        let config = try await decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["privateKey"] as? String, host.identityKey)
        XCTAssertEqual(config["passphrase"] as? String, host.passphrase)
        XCTAssertEqual(config["certificate"] as? String, host.certificate)
    }

    func testSSH2BridgePasswordIsNotPlacedInArgumentsOrPlainEnvironment() async throws {
        var host = Fixtures.host(authentication: .password)
        host.password = "fixture-login-value"

        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: host,
            runtime: SSH2BridgeRuntime(
                executable: URL(fileURLWithPath: "/tmp/runtime/termpilot-engine")
            ),
            inheritedEnvironment: [:]
        )

        XCTAssertFalse(launch.arguments.joined(separator: " ").contains("fixture-login-value"))
        XCTAssertFalse(launch.environment.joined(separator: " ").contains("fixture-login-value"))

        let config = try await decodedSSH2BridgeConfig(from: launch)
        XCTAssertEqual(config["password"] as? String, "fixture-login-value")
    }

    func testSSH2BridgeLaunchCarriesResolvedProxyConfiguration() async throws {
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
            runtime: SSH2BridgeRuntime(
                executable: URL(fileURLWithPath: "/tmp/runtime/termpilot-engine")
            ),
            inheritedEnvironment: [:]
        )

        XCTAssertFalse(launch.arguments.joined().contains("fixture-proxy-value"))
        XCTAssertFalse(launch.environment.joined().contains("fixture-proxy-value"))
        let config = try await decodedSSH2BridgeConfig(from: launch)
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
        let node = runtime.appendingPathComponent("termpilot-engine")
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
        XCTAssertEqual(found.executable, node)
    }

    func testExitCodeClassification() {
        XCTAssertEqual(SSHExitCategory.classify(exitCode: 0), .clean)
        XCTAssertEqual(SSHExitCategory.classify(exitCode: 255), .connectionFailed)
        XCTAssertEqual(SSHExitCategory.classify(exitCode: 130), .cancelled)
        XCTAssertEqual(SSHExitCategory.classify(exitCode: nil), .unknown)
    }

    private func decodedSSH2BridgeConfig(
        from launch: ProcessLaunchConfiguration
    ) async throws -> [String: Any] {
        let configuration = try XCTUnwrap(launch.privateConfiguration)
        let sender = Task { try await configuration.send() }
        let data = try await Task.detached {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: configuration.path))
            defer { try? file.close() }
            return try file.readToEnd() ?? Data()
        }.value
        try await sender.value
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
