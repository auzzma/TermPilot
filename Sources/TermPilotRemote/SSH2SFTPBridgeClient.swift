import Foundation
import TermPilotDomain

public struct SFTPTransferProgress: Equatable, Sendable {
    public var bytesTransferred: UInt64
    public var totalBytes: UInt64?

    public init(bytesTransferred: UInt64, totalBytes: UInt64?) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }
}

public actor SSH2SFTPBridgeClient {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private var nextID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var readyWaiters: [UUID: PendingRequest] = [:]
    private var progressHandlers: [Int: @Sendable (SFTPTransferProgress) -> Void] = [:]
    private var transferRequestIDs: [UUID: Int] = [:]
    private var requestTransferIDs: [Int: UUID] = [:]
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var isClosed = false
    private var isReady = false
    private var activeFileProtocol = "sftp"

    public init(
        host: TermPilotDomain.Host,
        sourceConnectionID: UUID? = nil,
        sourceSessionID: UUID? = nil,
        bridgeScript: URL,
        sftpBridgeScript: URL? = nil,
        runtime: SSH2BridgeRuntime,
        opensFileChannel: Bool = true,
        elevatesOperations: Bool = false,
        persistentElevation: Bool = false,
        elevationMethod: ServerToolsElevationMethod = .sudo,
        elevationPassword: String? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let host = try host.validated()
        let elevatesFileOperations =
            opensFileChannel
            && host.username != "root"
            && host.sftpFileProtocol != .scp
            && elevatesOperations
        let encodedConfig = try JSONEncoder()
            .encode(
                SFTPBridgeConfiguration(
                    hostname: host.hostname,
                    port: host.port,
                    username: host.username,
                    authentication: host.authentication.rawValue,
                    password: host.authentication == .password ? host.password : nil,
                    identityFile: host.authentication == .identityFile
                        ? host.identityFile
                        : nil,
                    privateKey: host.authentication == .identityFile
                        ? host.identityKey
                        : nil,
                    passphrase: host.authentication == .identityFile
                        ? host.passphrase
                        : nil,
                    certificate: host.authentication == .identityFile
                        ? host.certificate
                        : nil,
                    proxy: host.proxyConfiguration,
                    fileProtocol: host.sftpFileProtocol.rawValue,
                    filenameEncoding: host.sftpFilenameEncoding.rawValue,
                    usesSudo: elevatesFileOperations,
                    persistentElevation:
                        !opensFileChannel && persistentElevation,
                    elevationMethod: elevationMethod.rawValue,
                    elevationPassword: elevationPassword,
                    connectionID: sourceConnectionID?.uuidString,
                    sourceSessionID: sourceSessionID?.uuidString,
                    execOnly: !opensFileChannel
                )
            )
            .base64EncodedString()

        var environment = inheritedEnvironment
        environment["TERMPILOT_SFTP_BRIDGE_CONFIG_B64"] = encodedConfig
        if sourceConnectionID != nil {
            environment["TERMPILOT_SSH2_BRIDGE_CONFIG_B64"] = encodedConfig
            environment["TERMPILOT_SSH2_BRIDGE_SFTP_CLIENT"] = "1"
            environment["TERMPILOT_SFTP_BRIDGE_SCRIPT"] = sftpBridgeScript?.path
        }
        environment["TERMPILOT_SSH2_NODE_MODULES"] = runtime.nodeModulesDirectory.path
        environment["NODE_PATH"] = runtime.nodeModulesDirectory.path

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = runtime.nodeExecutable
        process.arguments = [bridgeScript.path]
        process.environment = environment
        process.currentDirectoryURL = bridgeScript.deletingLastPathComponent()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        readerTask = nil
        errorReaderTask = nil
        Task {
            await self.startReaders()
        }
    }

    private func startReaders() {
        guard readerTask == nil, errorReaderTask == nil else {
            return
        }
        readerTask = Task.detached(priority: .userInitiated) { [output] in
            await Self.readLines(from: output) { line in
                await self.handleLine(line)
            }
            await self.handleEOF()
        }
        errorReaderTask = Task.detached(priority: .utility) { [errorOutput] in
            await Self.drain(errorOutput)
        }
    }

    public func realPath(_ path: String) async throws -> String {
        let response: RealPathResponse = try await request(
            SFTPBridgeCommand(action: "realpath", path: path)
        )
        return response.path
    }

    public func terminalCurrentDirectory(
        sourceSessionID: UUID? = nil
    ) async throws -> String {
        let response: RealPathResponse = try await request(
            SFTPBridgeCommand(
                action: "terminalCWD",
                sourceSessionID: sourceSessionID?.uuidString
            )
        )
        return response.path
    }

    public func exec(
        command: String,
        timeoutMS: Int = 15_000,
        elevated: Bool = false
    ) async throws -> RemoteExecResponse {
        try await request(
            SFTPBridgeCommand(
                action: "exec",
                command: command,
                timeoutMS: timeoutMS,
                elevated: elevated
            )
        )
    }

    public func waitUntilReady() async throws {
        if isReady {
            return
        }
        guard !isClosed else {
            throw SSH2SFTPBridgeError.closed
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyWaiters[waiterID] = PendingRequest { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelReadyWaiter(waiterID)
            }
        }
    }

    public func supportsResumablePause() -> Bool {
        activeFileProtocol == "sftp"
    }

    public func listDirectory(at path: String) async throws -> [SFTPDirectoryEntry] {
        let response: ListResponse = try await request(
            SFTPBridgeCommand(action: "list", path: path)
        )
        return response.entries
    }

    public func stat(_ path: String) async throws -> SFTPDirectoryEntry {
        let response: StatResponse = try await request(
            SFTPBridgeCommand(action: "stat", path: path)
        )
        return response.entry
    }

    public func readTextFile(at path: String) async throws -> String {
        let response: TextResponse = try await request(
            SFTPBridgeCommand(action: "readText", path: path)
        )
        return response.text
    }

    public func writeTextFile(
        _ text: String,
        at path: String,
        overwrite: Bool
    ) async throws {
        let _: EmptyResponse = try await request(
            SFTPBridgeCommand(
                action: "writeText",
                path: path,
                overwrite: overwrite,
                content: text
            )
        )
    }

    public func createDirectory(at path: String) async throws {
        let _: EmptyResponse = try await request(
            SFTPBridgeCommand(action: "mkdir", path: path)
        )
    }

    public func createFile(at path: String) async throws {
        let _: EmptyResponse = try await request(
            SFTPBridgeCommand(
                action: "writeText",
                path: path,
                overwrite: false,
                content: ""
            )
        )
    }

    public func rename(from oldPath: String, to newPath: String) async throws {
        let _: EmptyResponse = try await request(
            SFTPBridgeCommand(
                action: "rename",
                oldPath: oldPath,
                newPath: newPath
            )
        )
    }

    public func delete(path: String, kind: SFTPEntryKind) async throws {
        let _: EmptyResponse = try await request(
            SFTPBridgeCommand(
                action: "delete",
                path: path,
                kind: kind.rawValue
            )
        )
    }

    public func setPermissions(_ permissions: UInt32, at path: String) async throws {
        let _: EmptyResponse = try await request(
            SFTPBridgeCommand(
                action: "chmod",
                path: path,
                permissions: permissions
            )
        )
    }

    public func download(
        remotePath: String,
        to localURL: URL,
        overwrite: Bool,
        transferID: UUID? = nil,
        options: SFTPTransferOptions? = nil,
        progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil
    ) async throws -> SFTPTransferResult {
        let response: TransferResponse = try await request(
            SFTPBridgeCommand(
                action: "download",
                remotePath: remotePath,
                localPath: localURL.path,
                overwrite: overwrite,
                transferKey: transferID?.uuidString,
                fileConcurrency: options?.fileConcurrency,
                chunkConcurrency: options?.chunkConcurrency,
                chunkSizeBytes: options?.chunkSizeBytes
            ),
            transferID: transferID,
            progress: progress
        )
        return SFTPTransferResult(
            bytesTransferred: response.bytesTransferred,
            chunkCount: 0,
            estimatedPeakBufferBytes:
                (options?.chunkSizeBytes ?? 256 * 1_024) * 2
        )
    }

    public func upload(
        localURL: URL,
        to remotePath: String,
        overwrite: Bool,
        transferID: UUID? = nil,
        options: SFTPTransferOptions? = nil,
        progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil
    ) async throws -> SFTPTransferResult {
        let response: TransferResponse = try await request(
            SFTPBridgeCommand(
                action: "upload",
                remotePath: remotePath,
                localPath: localURL.path,
                overwrite: overwrite,
                transferKey: transferID?.uuidString,
                fileConcurrency: options?.fileConcurrency,
                chunkConcurrency: options?.chunkConcurrency,
                chunkSizeBytes: options?.chunkSizeBytes
            ),
            transferID: transferID,
            progress: progress
        )
        return SFTPTransferResult(
            bytesTransferred: response.bytesTransferred,
            chunkCount: 0,
            estimatedPeakBufferBytes:
                (options?.chunkSizeBytes ?? 256 * 1_024) * 2
        )
    }

    public func pauseTransfer(id: UUID) async throws {
        try await sendTransferControl(action: "pause", transferID: id)
    }

    public func resumeTransfer(id: UUID) async throws {
        try await sendTransferControl(action: "resume", transferID: id)
    }

    private func sendTransferControl(
        action: String,
        transferID: UUID
    ) async throws {
        guard let requestID = transferRequestIDs[transferID] else {
            throw SSH2SFTPBridgeError.remote("Transfer is no longer active.")
        }
        let _: EmptyResponse = try await request(
            SFTPBridgeCommand(action: action, targetID: requestID)
        )
    }

    public func close() async {
        if !isClosed {
            let _: EmptyResponse? = try? await request(
                SFTPBridgeCommand(action: "close")
            )
        }
        transitionToClosed(with: SSH2SFTPBridgeError.closed)
        readerTask?.cancel()
        errorReaderTask?.cancel()
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func request<Response: Decodable>(
        _ command: SFTPBridgeCommand,
        transferID: UUID? = nil,
        progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil
    ) async throws -> Response {
        guard !isClosed, process.isRunning else {
            transitionToClosed(with: SSH2SFTPBridgeError.closed)
            throw SSH2SFTPBridgeError.closed
        }

        var command = command
        command.id = nextID
        nextID += 1
        let id = command.id
        if let transferID {
            transferRequestIDs[transferID] = id
            requestTransferIDs[id] = transferID
        }
        let payload = try JSONEncoder().encode(command)
        let line = payload + Data([0x0A])

        let responseData: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest { result in
                    continuation.resume(with: result)
                }
                if let progress {
                    progressHandlers[id] = progress
                }
                do {
                    try input.write(contentsOf: line)
                } catch {
                    transitionToClosed(with: error)
                }
            }
        } onCancel: {
            Task {
                await self.cancelRequest(id)
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: responseData)
    }

    private func cancelRequest(_ id: Int) {
        guard pending[id] != nil else {
            return
        }
        let command = SFTPBridgeCommand(
            action: "cancel",
            targetID: id
        )
        if let data = try? JSONEncoder().encode(command) + Data([0x0A]) {
            try? input.write(contentsOf: data)
        }
        pending.removeValue(forKey: id)?
            .resume(.failure(CancellationError()))
        progressHandlers.removeValue(forKey: id)
        clearTransferRequest(id: id)
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return
        }

        if object["event"] as? String == "progress",
           let id = object["id"] as? Int,
           let bytes = object["transferred"] as? NSNumber
        {
            let total = object["total"] as? NSNumber
            progressHandlers[id]?(
                SFTPTransferProgress(
                    bytesTransferred: bytes.uint64Value,
                    totalBytes: total?.uint64Value
                )
            )
            return
        }

        if object["id"] as? Int == 0 {
            if object["event"] as? String == "ready"
                || object["ok"] as? Bool == true
            {
                if let mode = object["mode"] as? String {
                    activeFileProtocol = mode
                }
                markReady()
                return
            }
            if let message = object["error"] as? String {
                failReadyWaiters(with: SSH2SFTPBridgeError.remote(message))
                return
            }
        }

        guard let id = object["id"] as? Int,
              let pendingRequest = pending.removeValue(forKey: id)
        else {
            return
        }
        progressHandlers.removeValue(forKey: id)
        clearTransferRequest(id: id)

        if object["ok"] as? Bool == true {
            let result = object["result"] ?? [:]
            let resultData =
                (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
            pendingRequest.resume(.success(resultData))
        } else {
            let message = object["error"] as? String
                ?? "The SFTP bridge returned an unknown error."
            pendingRequest.resume(.failure(SSH2SFTPBridgeError.remote(message)))
        }
    }

    private func markReady() {
        isReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(.success(Data()))
        }
    }

    private func failReadyWaiters(with error: any Error) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(.failure(error))
        }
    }

    private func cancelReadyWaiter(_ id: UUID) {
        readyWaiters.removeValue(forKey: id)?
            .resume(.failure(CancellationError()))
    }

    private func handleEOF() {
        transitionToClosed(with: SSH2SFTPBridgeError.closed)
    }

    private func transitionToClosed(with error: any Error) {
        isClosed = true
        isReady = false
        let requests = pending
        pending.removeAll()
        progressHandlers.removeAll()
        transferRequestIDs.removeAll()
        requestTransferIDs.removeAll()
        failReadyWaiters(with: error)
        for request in requests.values {
            request.resume(.failure(error))
        }
    }

    private func clearTransferRequest(id: Int) {
        guard let transferID = requestTransferIDs.removeValue(forKey: id) else {
            return
        }
        transferRequestIDs.removeValue(forKey: transferID)
    }

    private static func readLines(
        from handle: FileHandle,
        onLine: @escaping @Sendable (String) async -> Void
    ) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[..<newline])
                buffer.removeSubrange(buffer.startIndex ... newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    await onLine(line)
                }
            }
        }
    }

    private static func drain(_ handle: FileHandle) async {
        while !Task.isCancelled {
            if handle.availableData.isEmpty {
                break
            }
        }
    }
}

public enum SSH2SFTPBridgeError: Error, Equatable, LocalizedError, Sendable {
    case closed
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .closed:
            "The SFTP bridge is closed."
        case .remote(let message):
            message
        }
    }
}

private struct PendingRequest {
    let resume: @Sendable (Result<Data, any Error>) -> Void
}

private struct SFTPBridgeConfiguration: Encodable {
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
    var fileProtocol: String
    var filenameEncoding: String
    var usesSudo: Bool
    var persistentElevation: Bool
    var elevationMethod: String
    var elevationPassword: String?
    var connectionID: String?
    var sourceSessionID: String?
    var execOnly: Bool
}

private struct SFTPBridgeCommand: Encodable {
    var id = 0
    var action: String
    var command: String?
    var timeoutMS: Int?
    var elevated: Bool?
    var path: String?
    var oldPath: String?
    var newPath: String?
    var kind: String?
    var permissions: UInt32?
    var remotePath: String?
    var localPath: String?
    var overwrite: Bool?
    var targetID: Int?
    var content: String?
    var transferKey: String?
    var sourceSessionID: String?
    var fileConcurrency: Int?
    var chunkConcurrency: Int?
    var chunkSizeBytes: Int?
}

private struct EmptyResponse: Decodable {}

private struct RealPathResponse: Decodable {
    var path: String
}

public struct RemoteExecResponse: Decodable, Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var code: Int?
    public var signal: String?
}

private struct ListResponse: Decodable {
    var entries: [SFTPDirectoryEntry]
}

private struct StatResponse: Decodable {
    var entry: SFTPDirectoryEntry
}

private struct TextResponse: Decodable {
    var text: String
}

private struct TransferResponse: Decodable {
    var bytesTransferred: UInt64
}
