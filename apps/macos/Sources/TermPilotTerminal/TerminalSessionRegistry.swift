import Foundation
import TermPilotDomain

public struct TerminalSessionRecord: Equatable, Sendable {
    public var descriptor: SessionDescriptor
    public var lifecycle: SessionLifecycle
    public var title: String
    public var currentDirectory: String?

    public init(
        descriptor: SessionDescriptor,
        lifecycle: SessionLifecycle = .disconnected,
        title: String? = nil,
        currentDirectory: String? = nil
    ) {
        self.descriptor = descriptor
        self.lifecycle = lifecycle
        self.title = title ?? descriptor.title
        self.currentDirectory = currentDirectory
    }
}

public enum TerminalSessionEvent: Sendable {
    case inserted(TerminalSessionRecord)
    case changed(TerminalSessionRecord)
    case removed(UUID)
}

public actor TerminalSessionRegistry {
    private var records: [UUID: TerminalSessionRecord] = [:]
    private var observers: [UUID: AsyncStream<TerminalSessionEvent>.Continuation] = [:]

    public init() {}

    @discardableResult
    public func insert(
        descriptor: SessionDescriptor,
        lifecycle: SessionLifecycle = .disconnected
    ) -> TerminalSessionRecord {
        let record = TerminalSessionRecord(
            descriptor: descriptor,
            lifecycle: lifecycle
        )
        records[descriptor.id] = record
        publish(.inserted(record))
        return record
    }

    public func record(id: UUID) -> TerminalSessionRecord? {
        records[id]
    }

    public func allRecords() -> [TerminalSessionRecord] {
        records.values.sorted {
            $0.descriptor.title.localizedCaseInsensitiveCompare($1.descriptor.title)
                == .orderedAscending
        }
    }

    public func updateLifecycle(id: UUID, lifecycle: SessionLifecycle) {
        guard var record = records[id] else {
            return
        }
        record.lifecycle = lifecycle
        records[id] = record
        publish(.changed(record))
    }

    public func updateTitle(id: UUID, title: String) {
        guard var record = records[id] else {
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        record.title = trimmed
        records[id] = record
        publish(.changed(record))
    }

    public func updateCurrentDirectory(id: UUID, directory: String?) {
        guard var record = records[id] else {
            return
        }
        record.currentDirectory = directory
        records[id] = record
        publish(.changed(record))
    }

    public func remove(id: UUID) {
        guard records.removeValue(forKey: id) != nil else {
            return
        }
        publish(.removed(id))
    }

    public func events() -> AsyncStream<TerminalSessionEvent> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            observers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeObserver(id: observerID)
                }
            }
        }
    }

    private func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func publish(_ event: TerminalSessionEvent) {
        for continuation in observers.values {
            continuation.yield(event)
        }
    }
}
