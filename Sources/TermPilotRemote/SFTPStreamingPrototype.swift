import Foundation

public enum SFTPEntryKind: String, Codable, Sendable {
    case directory
    case file
    case symbolicLink
    case other
}

public struct SFTPDirectoryEntry: Codable, Equatable, Sendable {
    public let name: String
    public let kind: SFTPEntryKind
    public let size: UInt64?
    public let permissions: UInt32?
    public let modifiedAt: Date?

    public init(
        name: String,
        kind: SFTPEntryKind,
        size: UInt64? = nil,
        permissions: UInt32? = nil,
        modifiedAt: Date? = nil
    ) {
        self.name = name
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.modifiedAt = modifiedAt
    }
}

public protocol SFTPRemoteFile: Sendable {
    func read(at offset: UInt64, length: Int) async throws -> Data
    func write(_ data: Data, at offset: UInt64) async throws
    func close() async throws
}

public protocol SFTPBackend: Sendable {
    func listDirectory(at path: String) async throws -> [SFTPDirectoryEntry]
    func realPath(_ path: String) async throws -> String
    func createDirectory(at path: String) async throws
    func removeFile(at path: String) async throws
    func removeDirectory(at path: String) async throws
    func rename(from oldPath: String, to newPath: String) async throws
    func setPermissions(_ permissions: UInt32, at path: String) async throws
    func openFileForReading(at path: String) async throws -> any SFTPRemoteFile
    func openFileForWriting(at path: String) async throws -> any SFTPRemoteFile
}

public struct SFTPTransferResult: Equatable, Sendable {
    public let bytesTransferred: UInt64
    public let chunkCount: Int
    public let estimatedPeakBufferBytes: Int
}

public struct SFTPTransferOptions: Equatable, Sendable {
    public var fileConcurrency: Int
    public var chunkConcurrency: Int
    public var chunkSizeBytes: Int

    public init(
        fileConcurrency: Int,
        chunkConcurrency: Int,
        chunkSizeBytes: Int
    ) {
        self.fileConcurrency = fileConcurrency
        self.chunkConcurrency = chunkConcurrency
        self.chunkSizeBytes = chunkSizeBytes
    }
}

public struct SFTPStreamingPrototype: Sendable {
    public static let defaultChunkSize = 1 * 1_024 * 1_024
    public static let maximumChunkSize = 8 * 1_024 * 1_024

    private let backend: any SFTPBackend
    private let chunkSize: Int

    public init(
        backend: any SFTPBackend,
        chunkSize: Int = defaultChunkSize
    ) throws {
        guard (1 ... Self.maximumChunkSize).contains(chunkSize) else {
            throw SFTPTransferError.invalidChunkSize
        }
        self.backend = backend
        self.chunkSize = chunkSize
    }

    public func listDirectory(at path: String) async throws
        -> [SFTPDirectoryEntry]
    {
        try Task.checkCancellation()
        return try await backend.listDirectory(at: path)
    }

    public func realPath(_ path: String) async throws -> String {
        try Task.checkCancellation()
        return try await backend.realPath(path)
    }

    public func createDirectory(at path: String) async throws {
        try Task.checkCancellation()
        try await backend.createDirectory(at: path)
    }

    public func removeFile(at path: String) async throws {
        try Task.checkCancellation()
        try await backend.removeFile(at: path)
    }

    public func removeDirectory(at path: String) async throws {
        try Task.checkCancellation()
        try await backend.removeDirectory(at: path)
    }

    public func rename(from oldPath: String, to newPath: String) async throws {
        try Task.checkCancellation()
        try await backend.rename(from: oldPath, to: newPath)
    }

    public func setPermissions(_ permissions: UInt32, at path: String) async throws {
        try Task.checkCancellation()
        try await backend.setPermissions(permissions, at: path)
    }

    public func download(
        remotePath: String,
        to localURL: URL
    ) async throws -> SFTPTransferResult {
        let remoteFile = try await backend.openFileForReading(at: remotePath)
        do {
            let result = try await download(remoteFile: remoteFile, to: localURL)
            try await remoteFile.close()
            return result
        } catch {
            try? await remoteFile.close()
            throw error
        }
    }

    public func upload(
        localURL: URL,
        to remotePath: String
    ) async throws -> SFTPTransferResult {
        let temporaryPath = temporaryUploadPath(for: remotePath)
        let remoteFile = try await backend.openFileForWriting(at: temporaryPath)
        do {
            let result = try await upload(localURL: localURL, remoteFile: remoteFile)
            try await remoteFile.close()
            try Task.checkCancellation()
            try await backend.rename(from: temporaryPath, to: remotePath)
            return result
        } catch {
            try? await remoteFile.close()
            try? await backend.removeFile(at: temporaryPath)
            throw error
        }
    }

    private func download(
        remoteFile: any SFTPRemoteFile,
        to localURL: URL
    ) async throws -> SFTPTransferResult {
        guard FileManager.default.createFile(
            atPath: localURL.path,
            contents: nil
        ) || FileManager.default.fileExists(atPath: localURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let localFile = try FileHandle(forWritingTo: localURL)
        defer {
            try? localFile.close()
        }
        try localFile.truncate(atOffset: 0)

        var offset: UInt64 = 0
        var chunkCount = 0
        while true {
            try Task.checkCancellation()
            let data = try await remoteFile.read(
                at: offset,
                length: chunkSize
            )
            try Task.checkCancellation()
            guard !data.isEmpty else {
                break
            }
            guard data.count <= chunkSize else {
                throw SFTPTransferError.oversizedChunk
            }
            try localFile.write(contentsOf: data)
            offset += UInt64(data.count)
            chunkCount += 1
        }

        return result(bytesTransferred: offset, chunkCount: chunkCount)
    }

    private func upload(
        localURL: URL,
        remoteFile: any SFTPRemoteFile
    ) async throws -> SFTPTransferResult {
        let localFile = try FileHandle(forReadingFrom: localURL)
        defer {
            try? localFile.close()
        }

        var offset: UInt64 = 0
        var chunkCount = 0
        while true {
            try Task.checkCancellation()
            let data = try localFile.read(upToCount: chunkSize) ?? Data()
            guard !data.isEmpty else {
                break
            }
            try await remoteFile.write(data, at: offset)
            try Task.checkCancellation()
            offset += UInt64(data.count)
            chunkCount += 1
        }

        return result(bytesTransferred: offset, chunkCount: chunkCount)
    }

    private func result(
        bytesTransferred: UInt64,
        chunkCount: Int
    ) -> SFTPTransferResult {
        SFTPTransferResult(
            bytesTransferred: bytesTransferred,
            chunkCount: chunkCount,
            estimatedPeakBufferBytes: chunkSize * 2
        )
    }

    private func temporaryUploadPath(for remotePath: String) -> String {
        let suffix = ".termpilot-upload-\(UUID().uuidString).tmp"
        return remotePath + suffix
    }
}

public enum SFTPTransferError: Error, Equatable, Sendable {
    case invalidChunkSize
    case oversizedChunk
}
