import CryptoKit
import Foundation
import Security
import TermPilotDomain

public struct TermPilotBackupSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var hosts: [TermPilotDomain.Host]
    public var groups: [HostGroup]
    public var credentials: [SSHCredential]
    public var proxyProfiles: [SSHProxyProfile]
    public var portForwardRules: [PortForwardRule]
    public var automationScripts: [AutomationScript]
    public var hostNotes: [HostNote]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date = Date(),
        hosts: [TermPilotDomain.Host],
        groups: [HostGroup],
        credentials: [SSHCredential],
        proxyProfiles: [SSHProxyProfile],
        portForwardRules: [PortForwardRule],
        automationScripts: [AutomationScript],
        hostNotes: [HostNote]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.hosts = hosts
        self.groups = groups
        self.credentials = credentials
        self.proxyProfiles = proxyProfiles
        self.portForwardRules = portForwardRules
        self.automationScripts = automationScripts
        self.hostNotes = hostNotes
    }
}

public struct BackupImportSummary: Equatable, Sendable {
    public var hosts: Int
    public var deduplicatedHosts: Int
    public var groups: Int
    public var credentials: Int
    public var proxyProfiles: Int
    public var portForwardRules: Int
    public var automationScripts: Int
    public var hostNotes: Int

    public init(
        hosts: Int,
        deduplicatedHosts: Int,
        groups: Int,
        credentials: Int,
        proxyProfiles: Int,
        portForwardRules: Int,
        automationScripts: Int,
        hostNotes: Int
    ) {
        self.hosts = hosts
        self.deduplicatedHosts = deduplicatedHosts
        self.groups = groups
        self.credentials = credentials
        self.proxyProfiles = proxyProfiles
        self.portForwardRules = portForwardRules
        self.automationScripts = automationScripts
        self.hostNotes = hostNotes
    }
}

public enum EncryptedBackupCodec {
    public static let fileExtension = "tpbackup"
    public static let defaultPBKDF2Iterations = 600_000

    private static let magic = "TermPilotBackup"
    private static let formatVersion = 1
    private static let kdf = "PBKDF2-HMAC-SHA256"
    private static let cipher = "AES-256-GCM"
    private static let saltSize = 16
    private static let minimumPBKDF2Iterations = 100_000
    private static let maximumPBKDF2Iterations = 2_000_000
    private static let maximumFileSize = 100 * 1_024 * 1_024
    private static let authenticatedHeader = Data(
        "TermPilotBackup:v1:PBKDF2-HMAC-SHA256:AES-256-GCM".utf8
    )

    public static func encrypt(
        _ snapshot: TermPilotBackupSnapshot,
        password: String
    ) throws -> Data {
        try encrypt(
            snapshot,
            password: password,
            iterations: defaultPBKDF2Iterations
        )
    }

    static func encrypt(
        _ snapshot: TermPilotBackupSnapshot,
        password: String,
        iterations: Int
    ) throws -> Data {
        guard snapshot.schemaVersion
                == TermPilotBackupSnapshot.currentSchemaVersion
        else {
            throw EncryptedBackupError.unsupportedSnapshotVersion
        }
        try validatePassword(password)
        try validateIterations(iterations)

        let salt = try secureRandomData(count: saltSize)
        let key = try deriveKey(
            password: password,
            salt: salt,
            iterations: iterations
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(snapshot)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedHeader
        )
        guard let combined = sealed.combined else {
            throw EncryptedBackupError.encryptionFailed
        }
        let envelope = EncryptedBackupEnvelope(
            magic: magic,
            version: formatVersion,
            kdf: kdf,
            iterations: iterations,
            salt: salt.base64EncodedString(),
            cipher: cipher,
            payload: combined.base64EncodedString()
        )
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.sortedKeys]
        return try envelopeEncoder.encode(envelope)
    }

    public static func decrypt(
        _ data: Data,
        password: String
    ) throws -> TermPilotBackupSnapshot {
        guard data.count <= maximumFileSize else {
            throw EncryptedBackupError.fileTooLarge
        }
        try validatePassword(password)
        let envelope: EncryptedBackupEnvelope
        do {
            envelope = try JSONDecoder().decode(
                EncryptedBackupEnvelope.self,
                from: data
            )
        } catch {
            throw EncryptedBackupError.invalidFormat
        }
        guard envelope.magic == magic,
              envelope.version == formatVersion,
              envelope.kdf == kdf,
              envelope.cipher == cipher,
              let salt = Data(base64Encoded: envelope.salt),
              salt.count == saltSize,
              let payload = Data(base64Encoded: envelope.payload)
        else {
            throw EncryptedBackupError.invalidFormat
        }
        try validateIterations(envelope.iterations)
        let key = try deriveKey(
            password: password,
            salt: salt,
            iterations: envelope.iterations
        )
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: payload),
                using: key,
                authenticating: authenticatedHeader
            )
        } catch {
            throw EncryptedBackupError.authenticationFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: TermPilotBackupSnapshot
        do {
            snapshot = try decoder.decode(
                TermPilotBackupSnapshot.self,
                from: plaintext
            )
        } catch {
            throw EncryptedBackupError.invalidPayload
        }
        guard snapshot.schemaVersion
                == TermPilotBackupSnapshot.currentSchemaVersion
        else {
            throw EncryptedBackupError.unsupportedSnapshotVersion
        }
        return snapshot
    }

    private static func validatePassword(_ password: String) throws {
        guard password.count >= 8 else {
            throw EncryptedBackupError.passwordTooShort
        }
    }

    private static func validateIterations(_ iterations: Int) throws {
        guard (minimumPBKDF2Iterations ... maximumPBKDF2Iterations)
                .contains(iterations)
        else {
            throw EncryptedBackupError.invalidKeyDerivation
        }
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                $0.baseAddress!
            )
        }
        guard status == errSecSuccess else {
            throw EncryptedBackupError.randomGenerationFailed
        }
        return data
    }

    private static func deriveKey(
        password: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        try validateIterations(iterations)
        return SymmetricKey(
            data: try pbkdf2SHA256(
                password: password,
                salt: salt,
                iterations: iterations
            )
        )
    }

    static func pbkdf2SHA256(
        password: String,
        salt: Data,
        iterations: Int
    ) throws -> Data {
        guard iterations > 0 else {
            throw EncryptedBackupError.invalidKeyDerivation
        }
        let normalizedPassword =
            password.precomposedStringWithCanonicalMapping
        let passwordKey = SymmetricKey(
            data: Data(normalizedPassword.utf8)
        )
        var blockIndex = UInt32(1).bigEndian
        var firstInput = salt
        withUnsafeBytes(of: &blockIndex) {
            firstInput.append(contentsOf: $0)
        }
        var current = Array(
            HMAC<SHA256>.authenticationCode(
                for: firstInput,
                using: passwordKey
            )
        )
        var derived = current
        for _ in 1 ..< iterations {
            current = Array(
                HMAC<SHA256>.authenticationCode(
                    for: Data(current),
                    using: passwordKey
                )
            )
            for index in derived.indices {
                derived[index] ^= current[index]
            }
        }
        return Data(derived)
    }
}

public enum EncryptedBackupError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case passwordTooShort
    case invalidFormat
    case invalidKeyDerivation
    case authenticationFailed
    case invalidPayload
    case unsupportedSnapshotVersion
    case fileTooLarge
    case encryptionFailed
    case randomGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            "Backup password must contain at least 8 characters."
        case .invalidFormat:
            "The selected file is not a valid TermPilot backup."
        case .invalidKeyDerivation:
            "The backup uses unsupported password protection settings."
        case .authenticationFailed:
            "The backup password is incorrect or the file has been modified."
        case .invalidPayload:
            "The decrypted backup data is invalid."
        case .unsupportedSnapshotVersion:
            "This TermPilot backup version is not supported."
        case .fileTooLarge:
            "The backup file is too large."
        case .encryptionFailed:
            "Unable to encrypt the backup."
        case .randomGenerationFailed:
            "Unable to generate secure backup encryption data."
        }
    }
}

private struct EncryptedBackupEnvelope: Codable {
    var magic: String
    var version: Int
    var kdf: String
    var iterations: Int
    var salt: String
    var cipher: String
    var payload: String
}
