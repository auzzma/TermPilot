import Foundation

public enum SSHKeyType: String, Codable, CaseIterable, Sendable {
    case ed25519
    case ecdsa
    case rsa
}

public struct SSHKeyGenerationRequest: Codable, Equatable, Sendable {
    public var keyType: SSHKeyType
    public var bits: Int?
    public var passphrase: String?
    public var comment: String

    public init(
        keyType: SSHKeyType = .ed25519,
        bits: Int? = nil,
        passphrase: String? = nil,
        comment: String = ""
    ) {
        self.keyType = keyType
        self.bits = bits
        self.passphrase = passphrase
        self.comment = comment
    }

    public func validated() throws -> SSHKeyGenerationRequest {
        var copy = self
        switch keyType {
        case .ed25519:
            copy.bits = nil
        case .ecdsa:
            let bits = bits ?? 256
            guard [256, 384, 521].contains(bits) else {
                throw SSHCredentialKeyError.invalidECDSABits
            }
            copy.bits = bits
        case .rsa:
            let bits = bits ?? 4_096
            guard [1_024, 2_048, 4_096].contains(bits) else {
                throw SSHCredentialKeyError.invalidRSABits
            }
            copy.bits = bits
        }
        if copy.passphrase?.isEmpty == true {
            copy.passphrase = nil
        }
        copy.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

public struct GeneratedSSHKeyPair: Codable, Equatable, Sendable {
    public var privateKey: String
    public var publicKey: String

    public init(privateKey: String, publicKey: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

public enum SSHCredentialKeyGenerator {
    public static func generate(
        request: SSHKeyGenerationRequest,
        script: URL,
        runtime: SSH2BridgeRuntime,
        inheritedEnvironment: [String: String] =
            ProcessInfo.processInfo.environment
    ) async throws -> GeneratedSSHKeyPair {
        let request = try request.validated()
        return try await Task.detached(priority: .userInitiated) {
            let encoded = try JSONEncoder()
                .encode(request)
                .base64EncodedString()
            var environment = inheritedEnvironment
            environment["TERMPILOT_KEYGEN_CONFIG_B64"] = encoded
            environment["TERMPILOT_SSH2_NODE_MODULES"] =
                runtime.nodeModulesDirectory.path
            environment["NODE_PATH"] = runtime.nodeModulesDirectory.path

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let process = Process()
            process.executableURL = runtime.nodeExecutable
            process.arguments = [script.path]
            process.environment = environment
            process.currentDirectoryURL = script.deletingLastPathComponent()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SSHCredentialKeyError.generationFailed(
                    message?.isEmpty == false
                        ? message!
                        : "SSH key generation failed."
                )
            }
            do {
                return try JSONDecoder().decode(
                    GeneratedSSHKeyPair.self,
                    from: output
                )
            } catch {
                throw SSHCredentialKeyError.invalidGeneratorResponse
            }
        }.value
    }
}

public enum SSHAuthorizedKeyCommand {
    public static func make(publicKey: String) throws -> String {
        let key = try normalized(publicKey)
        let quotedKey = shellQuote(key)
        let authorizedKeys = "\"$HOME/.ssh/authorized_keys\""
        return [
            "umask 077",
            "mkdir -p \"$HOME/.ssh\"",
            "chmod 700 \"$HOME/.ssh\"",
            "touch \(authorizedKeys)",
            "chmod 600 \(authorizedKeys)",
            "(grep -Fqx \(quotedKey) \(authorizedKeys)"
                + " || printf '%s\\n' \(quotedKey) >> \(authorizedKeys))",
        ].joined(separator: " && ")
    }

    public static func normalized(_ publicKey: String) throws -> String {
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !key.contains("\n"),
              !key.contains("\r")
        else {
            throw SSHCredentialKeyError.invalidPublicKey
        }
        let fields = key.split(
            maxSplits: 2,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        let supported = [
            "ssh-ed25519",
            "ssh-rsa",
            "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
        ]
        guard fields.count >= 2,
              supported.contains(String(fields[0])),
              Data(base64Encoded: String(fields[1])) != nil
        else {
            throw SSHCredentialKeyError.invalidPublicKey
        }
        return key
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public enum SSHCredentialKeyError: Error, Equatable, Sendable {
    case invalidECDSABits
    case invalidRSABits
    case invalidPublicKey
    case generationFailed(String)
    case invalidGeneratorResponse
    case remoteInstallFailed(String)
    case keyAuthenticationRejected
}

extension SSHCredentialKeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidECDSABits:
            "ECDSA bits must be 256, 384, or 521."
        case .invalidRSABits:
            "RSA bits must be 1024, 2048, or 4096."
        case .invalidPublicKey:
            "The credential does not contain a valid SSH public key."
        case .generationFailed(let message):
            message
        case .invalidGeneratorResponse:
            "The SSH key generator returned invalid data."
        case .remoteInstallFailed(let message):
            message
        case .keyAuthenticationRejected:
            "The public key was installed, but the server rejected key authentication. The host's original login configuration was preserved."
        }
    }
}
