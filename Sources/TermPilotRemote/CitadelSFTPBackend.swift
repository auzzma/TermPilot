@preconcurrency import Citadel
import Foundation
import NIOCore

public actor CitadelSFTPBackend: SFTPBackend {
    private let client: SFTPClient

    public init(client: SFTPClient) {
        self.client = client
    }

    public func listDirectory(
        at path: String
    ) async throws -> [SFTPDirectoryEntry] {
        let responses = try await client.listDirectory(atPath: path)
        return responses
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                SFTPDirectoryEntry(
                    name: component.filename,
                    kind: Self.entryKind(
                        permissions: component.attributes.permissions
                    ),
                    size: component.attributes.size,
                    permissions: component.attributes.permissions,
                    modifiedAt: component.attributes
                        .accessModificationTime?
                        .modificationTime
                )
            }
    }

    public func realPath(_ path: String) async throws -> String {
        try await client.getRealPath(atPath: path)
    }

    public func createDirectory(at path: String) async throws {
        try await client.createDirectory(atPath: path)
    }

    public func removeFile(at path: String) async throws {
        try await client.remove(at: path)
    }

    public func removeDirectory(at path: String) async throws {
        try await client.rmdir(at: path)
    }

    public func rename(from oldPath: String, to newPath: String) async throws {
        try await client.rename(at: oldPath, to: newPath)
    }

    public func setPermissions(_ permissions: UInt32, at path: String) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = permissions
        try await client.setAttributes(
            at: path,
            to: attributes
        )
    }

    public func openFileForReading(
        at path: String
    ) async throws -> any SFTPRemoteFile {
        let file = try await client.openFile(
            filePath: path,
            flags: .read
        )
        return CitadelSFTPRemoteFile(file: file)
    }

    public func openFileForWriting(
        at path: String
    ) async throws -> any SFTPRemoteFile {
        let file = try await client.openFile(
            filePath: path,
            flags: [.write, .create, .truncate]
        )
        return CitadelSFTPRemoteFile(file: file)
    }

    public func close() async throws {
        try await client.close()
    }

    private static func entryKind(
        permissions: UInt32?
    ) -> SFTPEntryKind {
        guard let permissions else {
            return .other
        }
        switch permissions & 0o170_000 {
        case 0o040_000:
            return .directory
        case 0o100_000:
            return .file
        case 0o120_000:
            return .symbolicLink
        default:
            return .other
        }
    }
}

private actor CitadelSFTPRemoteFile: SFTPRemoteFile {
    private let file: SFTPFile

    init(file: SFTPFile) {
        self.file = file
    }

    func read(
        at offset: UInt64,
        length: Int
    ) async throws -> Data {
        guard let length = UInt32(exactly: length) else {
            throw SFTPTransferError.invalidChunkSize
        }
        let buffer = try await file.read(from: offset, length: length)
        return Data(buffer.readableBytesView)
    }

    func write(
        _ data: Data,
        at offset: UInt64
    ) async throws {
        try await file.write(ByteBuffer(bytes: data), at: offset)
    }

    func close() async throws {
        try await file.close()
    }
}
