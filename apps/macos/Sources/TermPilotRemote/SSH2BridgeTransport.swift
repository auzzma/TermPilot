import Foundation
import TermPilotCore
import TermPilotDomain

public struct SSH2BridgeRuntime: Equatable, Sendable {
    public var executable: URL
    public init(executable: URL) { self.executable = executable }
}

public enum SSH2BridgeRuntimeLocator {
    public static let bundledRuntimeDirectoryName = "engine"
    public static func bundledRuntime(in resourceDirectory: URL, fileManager: FileManager = .default) -> SSH2BridgeRuntime? {
        let executable = resourceDirectory.appendingPathComponent("engine/termpilot-engine")
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        return SSH2BridgeRuntime(executable: executable)
    }
}

public enum SSH2BridgeTransport {
    public static func launchConfiguration(
        host: TermPilotDomain.Host,
        runtime: SSH2BridgeRuntime,
        connectionID: UUID? = nil,
        sessionID: UUID? = nil,
        knownHostsFile: URL? = nil,
        autoAcceptHostKeys: Bool = false,
        forwardRule: Data? = nil,
        askPassExecutable: URL? = nil,
        askPassRequestDirectory: URL? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProcessLaunchConfiguration {
        let host = try host.validated()
        guard !host.hostname.hasPrefix("-") else {
            throw SSHConfigurationError.unsafeHostname
        }

        var policy: [String: Any] = ["protocol": "ssh", "host": host.hostname, "port": host.port, "username": host.username]
        if let proxy = host.proxyConfiguration {
            policy["proxy"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proxy))
        }
        try SharedCore.validateConnection(policy)

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
        var configData = try JSONEncoder().encode(config)
        if let forwardRule {
            var object = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
            object["forwardRule"] = try JSONSerialization.jsonObject(with: forwardRule)
            object["askPassExecutable"] = askPassExecutable?.path
            object["askPassRequestDirectory"] = askPassRequestDirectory?.path
            configData = try JSONSerialization.data(withJSONObject: object)
        }
        let privateConfiguration = try PrivateEngineConfiguration(configData)
        var environment = inheritedEnvironment.filter { !$0.key.hasPrefix("NODE_") && !$0.key.hasPrefix("TERMPILOT_") }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "TermPilot"
        let launch = try SharedCore.engineLaunch(engine: "sshTerminal", runtime: runtime.executable.path)
        return ProcessLaunchConfiguration(
            executable: launch.executable,
            arguments: launch.arguments + [privateConfiguration.path],
            environment: environment.map { "\($0.key)=\($0.value)" }.sorted(),
            currentDirectory: runtime.executable.deletingLastPathComponent().path,
            privateConfiguration: privateConfiguration
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
