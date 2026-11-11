import Foundation

/// Sends one key pair at a time. Acknowledgements confirm transport writes only,
/// never successful authentication at the remote login window.
@MainActor
final class ScreenSharingLoginInput {
    var send: ([String: Any]) -> Bool = { _ in false }
    var isAvailable: () -> Bool = { false }
    var changed: () -> Void = {}
    var timeout: Duration = .seconds(5)
    private(set) var isRunning = false
    private(set) var message = ""
    private var operation: UUID?
    private var pending: (id: String, continuation: CheckedContinuation<Bool, Never>)?
    private var deadline: Task<Void, Never>?

    func begin() -> UUID? {
        guard !isRunning, isAvailable() else { return nil }
        let id = UUID()
        operation = id; isRunning = true
        message = "Entering credential password…"
        changed()
        return id
    }

    func perform(password: String?, operation id: UUID) async {
        guard operation == id else { return }
        guard let password, !password.isEmpty else {
            fail("No desktop credential is available. Update the saved host or open Quick Connect again.", operation: id)
            return
        }
        guard password.unicodeScalars.count <= 1024, !password.unicodeScalars.contains(where: {
            [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }) else {
            fail("This password cannot be entered automatically. Enter it manually on the remote Mac.", operation: id)
            return
        }
        // Do not copy to either clipboard or enqueue the rest of the password.
        for scalar in password.unicodeScalars {
            let key = scalar.value <= 0xff ? scalar.value : scalar.value | 0x01000000
            guard await step(key, operation: id) else { return }
        }
        guard await step(0xff0d, operation: id), operation == id else { return }
        finish("Password and Return sent. Check the remote login result.")
    }

    func acknowledge(_ requestID: String) {
        guard pending?.id == requestID else { return }
        let continuation = pending?.continuation
        pending = nil; deadline?.cancel(); deadline = nil
        continuation?.resume(returning: true)
    }

    func fail(_ message: String, operation id: UUID) {
        guard operation == id else { return }
        finish(message)
    }

    func cancel() {
        guard isRunning else { return }
        finish("Credential password input cancelled.")
    }

    func reset() {
        cancel()
        message = ""
        changed()
    }

    private func finish(_ message: String) {
        operation = nil; isRunning = false; self.message = message
        deadline?.cancel(); deadline = nil
        let continuation = pending?.continuation; pending = nil
        continuation?.resume(returning: false)
        _ = send(["kind": "release"])
        changed()
    }

    private func step(_ key: UInt32, operation id: UUID) async -> Bool {
        guard operation == id else { return false }
        guard isAvailable(), !Task.isCancelled else { cancel(); return false }
        let request = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pending = (request, continuation)
            deadline = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.pending?.id == request else { return }
                self.fail("Credential password input timed out. Check the remote field before retrying.", operation: id)
            }
            if !send(["kind": "credentialKey", "key": key, "requestID": request]) {
                fail("Credential password input stopped because the connection is unavailable.", operation: id)
            }
        }
    }
}
