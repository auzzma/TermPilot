import Foundation
import TermPilotCore

public struct SavedBatchJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var configuration: String
    public var createdMs: Int64
    public var updatedMs: Int64
    public var revision: Int
}

/// Both desktop clients use the shared core's versioned, encrypted storage contract.
public struct BatchLibraryStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func request(_ fields: [String: Any]) throws -> [String: Any] {
        var request = fields
        request["method"] = "vault.batchStorage"
        request["directory"] = directory.path
        return try SharedCore.call(request)
    }

    public func list() throws -> [SavedBatchJob] {
        let value = try request(["operation": "list"])
        return try JSONDecoder().decode([SavedBatchJob].self, from: JSONSerialization.data(withJSONObject: value["items"] ?? []))
    }

    public func save(name: String, configuration: String, id: UUID?, revision: Int?) throws -> SavedBatchJob {
        var item: [String: Any] = ["name": name, "configuration": configuration]
        if let id { item["id"] = id.uuidString; item["revision"] = revision }
        let value = try request(["operation": "save", "item": item])
        return try JSONDecoder().decode(SavedBatchJob.self, from: JSONSerialization.data(withJSONObject: value["item"]!))
    }

    public func delete(_ item: SavedBatchJob) throws {
        _ = try request(["operation": "delete", "id": item.id.uuidString, "revision": item.revision])
    }
}
