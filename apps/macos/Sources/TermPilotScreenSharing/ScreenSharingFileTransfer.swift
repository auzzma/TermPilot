import AppKit
import Foundation
import UniformTypeIdentifiers

public struct ScreenSharingFileTransfer: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var direction: String
    public var stage: String
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var error: String?
    public var supportsPause: Bool { ["queued", "preparing", "transferring", "paused"].contains(stage) }
    public var isFinished: Bool { ["completed", "failed", "cancelled"].contains(stage) }
}

/// AppKit owns destination selection. The promise finishes only after the
/// native receiver has validated and atomically published the complete file.
@MainActor
final class ScreenSharingFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let remotePath: String
    let filename: String
    let runtime: ScreenSharingSessionRuntime
    init(path: String, name: String, runtime: ScreenSharingSessionRuntime) {
        remotePath = path; filename = name; self.runtime = runtime
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { filename }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        let completion = FilePromiseCompletion(completionHandler)
        MainActor.assumeIsolated {
            runtime.downloadPromisedFile(remotePath, to: url) { completion.finish($0) }
        }
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
    func provider() -> NSFilePromiseProvider {
        let ext = (filename as NSString).pathExtension
        let type = remotePath.hasSuffix("/") ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        // The delegate property is weak. Tie its lifetime to AppKit's promise,
        // including writes requested after the dragging session has ended.
        provider.userInfo = self
        return provider
    }
}

/// AppKit permits the completion on any queue; protect its exactly-once use
/// while the asynchronous transfer crosses the delegate's isolation boundary.
private final class FilePromiseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (((any Error)?) -> Void)?
    init(_ callback: @escaping ((any Error)?) -> Void) { self.callback = callback }
    func finish(_ error: (any Error)?) {
        let action = lock.withLock { let action = callback; callback = nil; return action }
        action?(error)
    }
}
