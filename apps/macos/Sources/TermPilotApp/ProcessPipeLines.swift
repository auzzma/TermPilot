import Darwin
import Foundation

/// Owns the read handle until EOF, failure or task cancellation.
enum ProcessPipeLines {
    static func read(
        from handle: FileHandle,
        maximumLineBytes: Int = 64 * 1024 * 1024,
        onLine: @escaping @Sendable (Data) async -> Void
    ) async throws {
        var buffer = Data()
        for try await chunk in chunks(from: handle) {
            try Task.checkCancellation()
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 10) {
                guard newline - start <= maximumLineBytes else { throw ReadError.lineTooLarge }
                await onLine(Data(buffer[start..<newline]))
                try Task.checkCancellation()
                start = newline + 1
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            guard buffer.count <= maximumLineBytes else { throw ReadError.lineTooLarge }
        }
        try Task.checkCancellation()
        guard buffer.isEmpty else { throw ReadError.incompleteLine }
    }

    private static func chunks(from handle: FileHandle) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            // FileHandle.bytes shares Foundation's serial AsyncBytes I/O actor.
            // An idle AI pipe can hold that actor in read() and prevent the batch
            // pipe from delivering even its first event. Use independent,
            // readiness-driven reads; never block a cooperative executor thread.
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                try? handle.close()
                continuation.finish(throwing: error)
                return
            }
            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue(label: "com.termpilot.process-pipe", qos: .userInitiated)
            )
            source.setEventHandler {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    continuation.yield(Data(bytes.prefix(count)))
                } else if count == 0 {
                    continuation.finish()
                } else if errno != EINTR && errno != EAGAIN {
                    continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
            }
            source.setCancelHandler { try? handle.close() }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }

    enum ReadError: Error { case lineTooLarge, incompleteLine }
}
