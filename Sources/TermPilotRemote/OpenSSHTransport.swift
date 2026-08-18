import Foundation
import TermPilotDomain

public struct ProcessLaunchConfiguration: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String]
    public var currentDirectory: String?

    public init(
        executable: String,
        arguments: [String],
        environment: [String],
        currentDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

public enum OpenSSHTransport {
    public static func launchConfiguration(
        host: TermPilotDomain.Host,
        knownHostsFile: URL,
        askPassExecutable: URL,
        askPassRequestDirectory: URL? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProcessLaunchConfiguration {
        let host = try host.validated()
        guard !host.hostname.hasPrefix("-") else {
            throw SSHConfigurationError.unsafeHostname
        }

        var arguments = [
            "-tt",
            "-p", String(host.port),
            "-l", host.username,
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "UpdateHostKeys=yes",
            "-o", "ControlMaster=no",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]

        switch host.authentication {
        case .agent:
            break
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
            ]
        case .identityFile:
            guard let identityFile = host.identityFile, !identityFile.isEmpty else {
                throw SSHConfigurationError.missingIdentityFile
            }
            arguments += [
                "-i", identityFile,
                "-o", "IdentitiesOnly=yes",
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
            ]
            if let certificateFile = host.certificate,
               !certificateFile.isEmpty
            {
                arguments += [
                    "-o", "CertificateFile=\(certificateFile)",
                ]
            }
        }

        arguments += ["--", host.hostname]

        var environment = inheritedEnvironment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["SSH_ASKPASS"] = askPassExecutable.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["TERMPILOT_ASKPASS_MODE"] = "1"
        environment["DISPLAY"] = environment["DISPLAY"] ?? "termpilot"
        if let askPassRequestDirectory {
            environment["TERMPILOT_ASKPASS_REQUEST_DIR"] =
                askPassRequestDirectory.path
        } else {
            environment.removeValue(forKey: "TERMPILOT_ASKPASS_REQUEST_DIR")
        }
        if let password = host.password, !password.isEmpty {
            environment["TERMPILOT_ASKPASS_SECRET_B64"] = Data(password.utf8)
                .base64EncodedString()
        } else {
            environment.removeValue(forKey: "TERMPILOT_ASKPASS_SECRET_B64")
        }

        return ProcessLaunchConfiguration(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        )
    }
}

public enum SSHConfigurationError: Error, Equatable, Sendable {
    case missingIdentityFile
    case unsafeHostname
}

extension SSHConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingIdentityFile:
            "The selected host has no private key file."
        case .unsafeHostname:
            "Hostnames beginning with a dash are not allowed."
        }
    }
}

public enum SSHExitCategory: String, Sendable {
    case clean
    case connectionFailed
    case cancelled
    case unknown

    public static func classify(exitCode: Int32?) -> SSHExitCategory {
        switch exitCode {
        case 0:
            .clean
        case 130, 143:
            .cancelled
        case 255:
            .connectionFailed
        default:
            .unknown
        }
    }
}
