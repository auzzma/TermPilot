import CryptoKit
import Foundation

public struct KnownHostRecord: Equatable, Identifiable, Sendable {
    public var id: Int { lineNumber }
    public let lineNumber: Int
    public let hostPattern: String
    public let algorithm: String
    public let fingerprint: String
}

public actor KnownHostsStore {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = try VaultStore.applicationSupportDirectory(fileManager: fileManager)
            self.fileURL = directory.appendingPathComponent("known_hosts")
        }
        try Self.ensureFile(at: self.fileURL, fileManager: fileManager)
    }

    public func records() throws -> [KnownHostRecord] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else {
                    return nil
                }
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 3,
                      let keyData = Data(base64Encoded: String(fields[2]))
                else {
                    return nil
                }
                let digest = SHA256.hash(data: keyData)
                let fingerprint = Data(digest)
                    .base64EncodedString()
                    .replacingOccurrences(of: "=", with: "")
                return KnownHostRecord(
                    lineNumber: index + 1,
                    hostPattern: String(fields[0]),
                    algorithm: String(fields[1]),
                    fingerprint: "SHA256:\(fingerprint)"
                )
            }
    }

    public func remove(lineNumber: Int) throws {
        try remove(lineNumbers: [lineNumber])
    }

    public func remove(lineNumbers: Set<Int>) throws {
        let targets = Set(lineNumbers.filter { $0 > 0 })
        guard !targets.isEmpty else {
            return
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let replacement = lines
            .enumerated()
            .filter { !targets.contains($0.offset + 1) }
            .map { String($0.element) }
            .joined(separator: "\n")
        try replacement.write(to: fileURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func appendOpenSSHLines(_ lines: [String]) throws {
        var seen = Set<String>()
        let sanitized = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .filter { seen.insert($0).inserted }
        guard !sanitized.isEmpty else {
            return
        }

        var existing = try String(contentsOf: fileURL, encoding: .utf8)
        let existingLines = Set(
            existing
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        let additions = sanitized.filter { !existingLines.contains($0) }
        guard !additions.isEmpty else {
            return
        }

        if !existing.isEmpty, !existing.hasSuffix("\n") {
            existing.append("\n")
        }
        existing.append(additions.joined(separator: "\n"))
        existing.append("\n")
        try existing.write(to: fileURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func ensureFile(
        at url: URL,
        fileManager: FileManager
    ) throws {
        if !fileManager.fileExists(atPath: url.path) {
            let created = fileManager.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
            guard created else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
