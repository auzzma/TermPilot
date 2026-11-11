import Foundation
import TermPilotDomain

public struct ProcessLaunchConfiguration: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String]
    public var currentDirectory: String?
    public var privateConfiguration: PrivateEngineConfiguration?

    public init(
        executable: String,
        arguments: [String],
        environment: [String],
        currentDirectory: String? = nil,
        privateConfiguration: PrivateEngineConfiguration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.privateConfiguration = privateConfiguration
    }

    public func preparedForLaunch() throws -> ProcessLaunchConfiguration {
        guard let privateConfiguration else { return self }
        let next = try privateConfiguration.freshPipe()
        var launch = self
        launch.arguments = arguments.map { $0 == privateConfiguration.path ? next.path : $0 }
        launch.privateConfiguration = next
        return launch
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
