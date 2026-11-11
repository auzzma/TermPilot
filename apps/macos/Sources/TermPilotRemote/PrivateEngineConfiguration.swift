import Darwin
import Foundation

/// Credentials travel through this one-shot pipe, separate from the terminal
/// PTY. The path is public; neither the environment nor argv contains secrets.
public final class PrivateEngineConfiguration: @unchecked Sendable, Equatable {
    public let path: String
    private let directory: URL
    private let lock = NSLock()
    // Retain the in-memory launch template for reconnects. Only the FIFO is
    // one-shot; credentials are never placed in argv, the environment or a file.
    private var configuration: Data
    private var sent = false

    public static func == (lhs: PrivateEngineConfiguration, rhs: PrivateEngineConfiguration) -> Bool { lhs === rhs }

    public init(_ configuration: Data) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TermPilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("configuration.pipe").path
        guard mkfifo(path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.configuration = configuration
    }

    deinit {
        configuration.resetBytes(in: 0..<configuration.count)
        try? FileManager.default.removeItem(at: directory)
    }

    public func freshPipe() throws -> PrivateEngineConfiguration {
        try lock.withLock { try PrivateEngineConfiguration(configuration) }
    }

    public func send() async throws {
        let sender = Task.detached(priority: .userInitiated) { [self] in
            let data: Data? = lock.withLock {
                guard !sent else { return nil }
                sent = true
                return configuration
            }
            guard var data else { return }
            defer {
                data.resetBytes(in: 0..<data.count)
                try? FileManager.default.removeItem(at: directory)
            }
            let deadline = Date().addingTimeInterval(20)
            var descriptor: Int32 = -1
            while descriptor < 0 {
                descriptor = Darwin.open(path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
                if descriptor >= 0 { break }
                guard errno == ENXIO, Date() < deadline else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try await Task.sleep(for: .milliseconds(25))
            }
            defer { Darwin.close(descriptor) }
            // Blocking writes happen on the detached task, never the UI thread.
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += count
                }
            }
        }
        try await withTaskCancellationHandler {
            try await sender.value
        } onCancel: {
            sender.cancel()
        }
    }
}
