import Foundation
import TermPilotDomain

public struct SSH2BridgeRuntime: Equatable, Sendable {
    public var nodeExecutable: URL
    public var nodeModulesDirectory: URL

    public init(
        nodeExecutable: URL,
        nodeModulesDirectory: URL
    ) {
        self.nodeExecutable = nodeExecutable
        self.nodeModulesDirectory = nodeModulesDirectory
    }
}

public enum SSH2BridgeRuntimeLocator {
    public static let bundledRuntimeDirectoryName = "ssh2-bridge-runtime"

    public static func bundledRuntime(
        in resourceDirectory: URL,
        fileManager: FileManager = .default
    ) -> SSH2BridgeRuntime? {
        let runtimeDirectory = resourceDirectory
            .appendingPathComponent(bundledRuntimeDirectoryName, isDirectory: true)
        let nodeExecutable = runtimeDirectory
            .appendingPathComponent("node/bin/node")
        let nodeModules = runtimeDirectory
            .appendingPathComponent("node_modules", isDirectory: true)

        guard fileManager.isExecutableFile(atPath: nodeExecutable.path),
              isDirectory(nodeModules, fileManager: fileManager)
        else {
            return nil
        }
        return SSH2BridgeRuntime(
            nodeExecutable: nodeExecutable,
            nodeModulesDirectory: nodeModules
        )
    }

    private static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }
}

public enum SSH2BridgeTransport {
    public static func launchConfiguration(
        host: TermPilotDomain.Host,
        bridgeScript: URL,
        runtime: SSH2BridgeRuntime,
        connectionID: UUID? = nil,
        sessionID: UUID? = nil,
        knownHostsFile: URL? = nil,
        autoAcceptHostKeys: Bool = false,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProcessLaunchConfiguration {
        let host = try host.validated()
        guard !host.hostname.hasPrefix("-") else {
            throw SSHConfigurationError.unsafeHostname
        }

        let config = SSH2BridgeConfiguration(
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authentication: host.authentication.rawValue,
            password: host.authentication == .password ? host.password : nil,
            identityFile: host.authentication == .identityFile ? host.identityFile : nil,
            privateKey: host.authentication == .identityFile ? host.identityKey : nil,
            passphrase: host.authentication == .identityFile ? host.passphrase : nil,
            certificate: host.authentication == .identityFile ? host.certificate : nil,
            proxy: host.proxyConfiguration,
            connectionID: connectionID?.uuidString ?? UUID().uuidString,
            sessionID: sessionID?.uuidString,
            knownHostsFile: knownHostsFile?.path,
            autoAcceptHostKeys: autoAcceptHostKeys
        )
        let encodedConfig = try JSONEncoder()
            .encode(config)
            .base64EncodedString()

        var environment = inheritedEnvironment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "TermPilot"
        environment["TERMPILOT_SSH2_BRIDGE_CONFIG_B64"] = encodedConfig
        environment["TERMPILOT_SSH2_NODE_MODULES"] = runtime.nodeModulesDirectory.path
        environment["NODE_PATH"] = runtime.nodeModulesDirectory.path

        return ProcessLaunchConfiguration(
            executable: runtime.nodeExecutable.path,
            arguments: [
                bridgeScript.path,
            ],
            environment: environment
                .map { "\($0.key)=\($0.value)" }
                .sorted(),
            currentDirectory: bridgeScript.deletingLastPathComponent().path
        )
    }
}

private struct SSH2BridgeConfiguration: Encodable {
    var hostname: String
    var port: Int
    var username: String
    var authentication: String
    var password: String?
    var identityFile: String?
    var privateKey: String?
    var passphrase: String?
    var certificate: String?
    var proxy: SSHProxyConfiguration?
    var connectionID: String
    var sessionID: String?
    var knownHostsFile: String?
    var autoAcceptHostKeys: Bool
}
