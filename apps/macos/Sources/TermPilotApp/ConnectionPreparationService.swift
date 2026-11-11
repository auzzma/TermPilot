import Foundation
import TermPilotCore
import TermPilotDomain
import TermPilotPersistence

/// Blocking local FFI/process work never runs on MainActor or the cloud-sync worker.
enum ConnectionPreparationService {
    private static let queue = DispatchQueue(label: "com.termpilot.connection-preparation", qos: .userInitiated)

    static func run<T: Sendable>(
        onCancellation: (@Sendable (T) async -> Void)? = nil,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let value: T = try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
        if Task.isCancelled {
            await onCancellation?(value)
            throw CancellationError()
        }
        return value
    }

    static func prepare(host: TermPilotDomain.Host, credentials: [SSHCredential], proxies: [SSHProxyProfile],
                        databaseURL: URL? = nil, keyURL: URL? = nil) async throws -> TermPilotDomain.Host {
        try await run {
            let resolved = try host.applyingConnectionSettings(credentials: credentials, proxyProfiles: proxies)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved))
            let directory = try databaseURL?.deletingLastPathComponent() ?? VaultStore.applicationSupportDirectory()
            var request: [String: Any] = ["method": "sync.checkConnection", "directory": directory.path, "host": object]
            if let databaseURL { request["databasePath"] = databaseURL.path }
            if let keyURL { request["keyPath"] = keyURL.path }
            _ = try SharedCore.call(request)
            return resolved
        }
    }
}
