import Foundation

struct LocalCommandResult: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var code: Int32
}

enum LocalCommandExecutorError: LocalizedError, Equatable, Sendable {
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .timedOut(let milliseconds):
            String(
                format: AppLocalization.string(
                    "Local command timed out after %@ ms."
                ),
                String(milliseconds)
            )
        }
    }
}

enum LocalCommandExecutor {
    static func run(
        command: String,
        shell: String = "/bin/zsh",
        workingDirectory: String? = nil,
        timeoutMS: Int = 15_000
    ) async throws -> LocalCommandResult {
        let operation = LocalCommandOperation(
            command: command,
            shell: shell,
            workingDirectory: workingDirectory
        )

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(
                of: LocalCommandResult.self
            ) { group in
                group.addTask {
                    try operation.run()
                }
                group.addTask {
                    try await Task.sleep(
                        for: .milliseconds(max(timeoutMS, 1))
                    )
                    operation.stop(reason: .timeout(timeoutMS))
                    throw LocalCommandExecutorError.timedOut(timeoutMS)
                }

                defer {
                    group.cancelAll()
                    operation.stop(reason: .cancelled)
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                return result
            }
        } onCancel: {
            operation.stop(reason: .cancelled)
        }
    }
}

private enum LocalCommandStopReason {
    case cancelled
    case timeout(Int)
}

private final class LocalCommandOperation: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stateLock = NSLock()
    private let outputLock = NSLock()
    private var stopReason: LocalCommandStopReason?
    private var stdoutData = Data()
    private var stderrData = Data()

    init(
        command: String,
        shell: String,
        workingDirectory: String?
    ) {
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment
        process.currentDirectoryURL = Self.existingDirectoryURL(
            for: workingDirectory
        ) ?? FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    private static func existingDirectoryURL(
        for value: String?
    ) -> URL? {
        let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            return nil
        }

        let url: URL
        if value.hasPrefix("file://"),
           let fileURL = URL(string: value),
           fileURL.isFileURL
        {
            url = fileURL
        } else {
            let path = NSString(string: value).expandingTildeInPath
            guard NSString(string: path).isAbsolutePath else {
                return nil
            }
            url = URL(fileURLWithPath: path, isDirectory: true)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        return url.standardizedFileURL
    }

    func run() throws -> LocalCommandResult {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] in
            self?.append($0.availableData, toStandardError: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] in
            self?.append($0.availableData, toStandardError: true)
        }

        if let reason = currentStopReason() {
            throw error(for: reason)
        }

        do {
            try process.run()
        } catch {
            clearReadabilityHandlers()
            throw error
        }
        if let reason = currentStopReason() {
            stopProcess()
            clearReadabilityHandlers()
            throw error(for: reason)
        }

        process.waitUntilExit()
        clearReadabilityHandlers()
        append(
            stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            toStandardError: false
        )
        append(
            stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            toStandardError: true
        )

        if let reason = currentStopReason() {
            throw error(for: reason)
        }
        let output = collectedOutput()
        return LocalCommandResult(
            stdout: String(decoding: output.stdout, as: UTF8.self),
            stderr: String(decoding: output.stderr, as: UTF8.self),
            code: process.terminationStatus
        )
    }

    func stop(reason: LocalCommandStopReason) {
        stateLock.lock()
        if stopReason == nil {
            stopReason = reason
        }
        stateLock.unlock()
        stopProcess()
    }

    private func stopProcess() {
        stateLock.lock()
        let isRunning = process.isRunning
        stateLock.unlock()
        if isRunning {
            process.terminate()
        }
    }

    private func currentStopReason() -> LocalCommandStopReason? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopReason
    }

    private func error(for reason: LocalCommandStopReason) -> any Error {
        switch reason {
        case .cancelled:
            CancellationError()
        case .timeout(let milliseconds):
            LocalCommandExecutorError.timedOut(milliseconds)
        }
    }

    private func append(_ data: Data, toStandardError: Bool) {
        guard !data.isEmpty else {
            return
        }
        outputLock.lock()
        if toStandardError {
            stderrData.append(data)
        } else {
            stdoutData.append(data)
        }
        outputLock.unlock()
    }

    private func collectedOutput() -> (stdout: Data, stderr: Data) {
        outputLock.lock()
        defer { outputLock.unlock() }
        return (stdoutData, stderrData)
    }

    private func clearReadabilityHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }
}
