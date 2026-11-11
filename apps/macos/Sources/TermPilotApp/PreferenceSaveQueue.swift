import Foundation
import SwiftUI
import TermPilotCore
import TermPilotPersistence

/// Coalesces edits by field; a failed batch remains queued for retry or quit-time flush.
@MainActor
final class PreferenceSaveQueue: ObservableObject {
    static let shared = PreferenceSaveQueue()
    @Published private(set) var error: String?
    private(set) var revision: UInt64 = 0
    private var pending: [String: Data] = [:]
    private var worker: Task<Void, Never>?
    private var inFlightFields = Set<String>()
    func hasPending(_ field: String) -> Bool { pending[field] != nil || inFlightFields.contains(field) }
    private let save: @Sendable ([String: Data]) async throws -> Void

    init(save: @escaping @Sendable ([String: Data]) async throws -> Void = { fields in
        try await ConnectionPreparationService.run {
            let values = try fields.mapValues { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            _ = try SharedCore.call(["method": "sync.preferences",
                "directory": try VaultStore.applicationSupportDirectory().path, "values": values])
        }
    }) { self.save = save }

    func enqueue(_ value: Data, field: String) {
        revision &+= 1
        pending[field] = value
        start()
    }

    private func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await self?.drain()
            self?.worker = nil
            if let self, !self.pending.isEmpty, self.error == nil { self.start() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let batch = pending
            pending.removeAll()
            inFlightFields = Set(batch.keys)
            do {
                try await save(batch)
                revision &+= 1
                error = nil
                inFlightFields.removeAll()
            } catch {
                // Never replace a newer edit with a failed, older value.
                inFlightFields.removeAll()
                pending.merge(batch) { latest, _ in latest }
                self.error = error.localizedDescription
                return
            }
        }
    }

    func retry() { start() }

    func flush() async throws {
        if worker == nil, !pending.isEmpty { start() }
        if let worker { await worker.value }
        if let error { throw AppStateError.workflowRunFailed(error) }
        if !pending.isEmpty { try await flush() }
    }
}
