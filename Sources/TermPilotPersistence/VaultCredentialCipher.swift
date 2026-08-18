import CryptoKit
import Foundation
import Security

struct VaultCredentialCipher: Sendable {
    private static let prefix = "enc:v1:"
    private static let keySize = 32

    private let keyData: Data

    init(keyURL: URL) throws {
        let fileManager = FileManager.default
        let directory = keyURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if fileManager.fileExists(atPath: keyURL.path) {
            keyData = try Data(contentsOf: keyURL)
            guard keyData.count == Self.keySize else {
                throw PersistenceError.invalidCredentialKey
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )
            return
        }

        var data = Data(count: Self.keySize)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, Self.keySize, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PersistenceError.credentialKeyGenerationFailed(status)
        }

        try data.write(to: keyURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyURL.path
        )
        keyData = data
    }

    func encryptField(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else {
            return value
        }
        if value.hasPrefix(Self.prefix), (try? decryptField(value)) != nil {
            return value
        }
        let key = SymmetricKey(data: keyData)
        let sealedBox = try AES.GCM.seal(Data(value.utf8), using: key)
        guard let combined = sealedBox.combined else {
            throw PersistenceError.credentialEncryptionFailed
        }
        return Self.prefix + combined.base64EncodedString()
    }

    func decryptField(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else {
            return value
        }
        guard value.hasPrefix(Self.prefix) else {
            return value
        }
        let encoded = String(value.dropFirst(Self.prefix.count))
        guard let combined = Data(base64Encoded: encoded) else {
            throw PersistenceError.credentialDecryptionFailed
        }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: keyData)
            )
            guard let value = String(data: plaintext, encoding: .utf8) else {
                throw PersistenceError.credentialDecryptionFailed
            }
            return value
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.credentialDecryptionFailed
        }
    }
}
