import Foundation
import TermPilotRemote
import XCTest

final class SFTPStreamingTests: XCTestCase {
    func testDownloadUsesBoundedChunksAndPreservesBytes() async throws {
        let source = fixtureData(count: 2_500_123)
        let readFile = FakeSFTPFile(contents: source)
        let writeFile = FakeSFTPFile()
        let backend = FakeSFTPBackend(
            readFile: readFile,
            writeFile: writeFile
        )
        let chunkSize = 64 * 1_024
        let prototype = try SFTPStreamingPrototype(
            backend: backend,
            chunkSize: chunkSize
        )
        let destination = temporaryFileURL()

        let result = try await prototype.download(
            remotePath: "/large.bin",
            to: destination
        )

        let downloaded = try Data(contentsOf: destination)
        let readState = await readFile.state()
        XCTAssertEqual(downloaded, source)
        XCTAssertEqual(result.bytesTransferred, UInt64(source.count))
        XCTAssertEqual(readState.maximumReadLength, chunkSize)
        XCTAssertTrue(readState.closed)
        XCTAssertEqual(
            result.estimatedPeakBufferBytes,
            chunkSize * 2
        )
        XCTAssertLessThan(
            result.estimatedPeakBufferBytes,
            64 * 1_024 * 1_024
        )
    }

    func testUploadUsesBoundedChunksAndPreservesBytes() async throws {
        let source = fixtureData(count: 1_500_017)
        let localURL = temporaryFileURL()
        try source.write(to: localURL)

        let readFile = FakeSFTPFile()
        let writeFile = FakeSFTPFile()
        let backend = FakeSFTPBackend(
            readFile: readFile,
            writeFile: writeFile
        )
        let chunkSize = 32 * 1_024
        let prototype = try SFTPStreamingPrototype(
            backend: backend,
            chunkSize: chunkSize
        )

        let result = try await prototype.upload(
            localURL: localURL,
            to: "/uploaded.bin"
        )

        let writeState = await writeFile.state()
        let backendState = await backend.state()
        XCTAssertEqual(writeState.contents, source)
        XCTAssertEqual(writeState.maximumWriteLength, chunkSize)
        XCTAssertEqual(result.bytesTransferred, UInt64(source.count))
        XCTAssertTrue(writeState.closed)
        XCTAssertEqual(
            backendState.writePath?.hasPrefix("/uploaded.bin.termpilot-upload-"),
            true
        )
        XCTAssertEqual(backendState.renames.count, 1)
        XCTAssertEqual(backendState.renames.first?.to, "/uploaded.bin")
        XCTAssertTrue(backendState.removedFiles.isEmpty)
    }

    func testCancelledUploadRemovesTemporaryRemoteFile() async throws {
        let source = fixtureData(count: 4 * 1_024 * 1_024)
        let localURL = temporaryFileURL()
        try source.write(to: localURL)

        let writeFile = FakeSFTPFile(writeDelayNanoseconds: 10_000_000)
        let backend = FakeSFTPBackend(
            readFile: FakeSFTPFile(),
            writeFile: writeFile
        )
        let prototype = try SFTPStreamingPrototype(
            backend: backend,
            chunkSize: 64 * 1_024
        )
        let transfer = Task {
            try await prototype.upload(
                localURL: localURL,
                to: "/cancel-upload.bin"
            )
        }

        try await Task.sleep(nanoseconds: 25_000_000)
        transfer.cancel()

        do {
            _ = try await transfer.value
            XCTFail("Expected transfer cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let fileState = await writeFile.state()
        let backendState = await backend.state()
        XCTAssertTrue(fileState.closed)
        XCTAssertEqual(backendState.removedFiles, [try XCTUnwrap(backendState.writePath)])
        XCTAssertTrue(backendState.renames.isEmpty)
    }

    func testCancellationClosesRemoteFile() async throws {
        let readFile = FakeSFTPFile(
            contents: fixtureData(count: 4 * 1_024 * 1_024),
            readDelayNanoseconds: 10_000_000
        )
        let backend = FakeSFTPBackend(
            readFile: readFile,
            writeFile: FakeSFTPFile()
        )
        let prototype = try SFTPStreamingPrototype(
            backend: backend,
            chunkSize: 64 * 1_024
        )
        let destination = temporaryFileURL()
        let transfer = Task {
            try await prototype.download(
                remotePath: "/cancel.bin",
                to: destination
            )
        }

        try await Task.sleep(nanoseconds: 25_000_000)
        transfer.cancel()

        do {
            _ = try await transfer.value
            XCTFail("Expected transfer cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let state = await readFile.state()
        XCTAssertTrue(state.closed)
        XCTAssertLessThanOrEqual(state.maximumReadLength, 64 * 1_024)
    }

    func testDirectoryListingRemainsStructured() async throws {
        let entry = SFTPDirectoryEntry(
            name: "archive",
            kind: .directory,
            permissions: 0o040_755
        )
        let backend = FakeSFTPBackend(
            readFile: FakeSFTPFile(),
            writeFile: FakeSFTPFile(),
            entries: [entry]
        )
        let prototype = try SFTPStreamingPrototype(backend: backend)

        let entries = try await prototype.listDirectory(at: "/srv")

        XCTAssertEqual(entries, [entry])
    }

    private func fixtureData(count: Int) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func temporaryFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPilotSFTP-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private actor FakeSFTPBackend: SFTPBackend {
    struct State: Sendable {
        let writePath: String?
        let removedFiles: [String]
        let renames: [(from: String, to: String)]
    }

    private let readFile: FakeSFTPFile
    private let writeFile: FakeSFTPFile
    private let entries: [SFTPDirectoryEntry]
    private var writePath: String?
    private var removedFiles: [String] = []
    private var renames: [(from: String, to: String)] = []

    init(
        readFile: FakeSFTPFile,
        writeFile: FakeSFTPFile,
        entries: [SFTPDirectoryEntry] = []
    ) {
        self.readFile = readFile
        self.writeFile = writeFile
        self.entries = entries
    }

    func listDirectory(at path: String) async throws
        -> [SFTPDirectoryEntry]
    {
        entries
    }

    func realPath(_ path: String) async throws -> String {
        path
    }

    func createDirectory(at path: String) async throws {}

    func removeFile(at path: String) async throws {
        removedFiles.append(path)
    }

    func removeDirectory(at path: String) async throws {}

    func rename(from oldPath: String, to newPath: String) async throws {
        renames.append((oldPath, newPath))
    }

    func setPermissions(_ permissions: UInt32, at path: String) async throws {}

    func openFileForReading(
        at path: String
    ) async throws -> any SFTPRemoteFile {
        readFile
    }

    func openFileForWriting(
        at path: String
    ) async throws -> any SFTPRemoteFile {
        writePath = path
        return writeFile
    }

    func state() -> State {
        State(
            writePath: writePath,
            removedFiles: removedFiles,
            renames: renames
        )
    }
}

private actor FakeSFTPFile: SFTPRemoteFile {
    struct State: Sendable {
        let contents: Data
        let maximumReadLength: Int
        let maximumWriteLength: Int
        let closed: Bool
    }

    private var contents: Data
    private var maximumReadLength = 0
    private var maximumWriteLength = 0
    private var closed = false
    private let readDelayNanoseconds: UInt64
    private let writeDelayNanoseconds: UInt64

    init(
        contents: Data = Data(),
        readDelayNanoseconds: UInt64 = 0,
        writeDelayNanoseconds: UInt64 = 0
    ) {
        self.contents = contents
        self.readDelayNanoseconds = readDelayNanoseconds
        self.writeDelayNanoseconds = writeDelayNanoseconds
    }

    func read(
        at offset: UInt64,
        length: Int
    ) async throws -> Data {
        maximumReadLength = max(maximumReadLength, length)
        if readDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: readDelayNanoseconds)
        }
        let start = Int(offset)
        guard start < contents.count else {
            return Data()
        }
        let end = min(contents.count, start + length)
        return Data(contents[start ..< end])
    }

    func write(
        _ data: Data,
        at offset: UInt64
    ) async throws {
        maximumWriteLength = max(maximumWriteLength, data.count)
        if writeDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: writeDelayNanoseconds)
        }
        let start = Int(offset)
        guard start == contents.count else {
            throw FakeSFTPError.nonSequentialWrite
        }
        contents.append(data)
    }

    func close() async throws {
        closed = true
    }

    func state() -> State {
        State(
            contents: contents,
            maximumReadLength: maximumReadLength,
            maximumWriteLength: maximumWriteLength,
            closed: closed
        )
    }
}

private enum FakeSFTPError: Error {
    case nonSequentialWrite
}
