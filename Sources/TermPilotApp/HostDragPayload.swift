import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let termPilotHostID = UTType(exportedAs: "com.termpilot.host-id")
    static let termPilotHostGroupID = UTType(
        exportedAs: "com.termpilot.host-group-id"
    )
}

enum HostDragPayload {
    static let typeIdentifier = UTType.termPilotHostID.identifier
    static let fallbackTypeIdentifier = UTType.plainText.identifier
    static let acceptedTypes: [UTType] = [.termPilotHostID, .plainText]

    static func provider(for hostID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(hostID.uuidString.utf8)
        provider.suggestedName = hostID.uuidString
        provider.registerDataRepresentation(
            forTypeIdentifier: typeIdentifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: fallbackTypeIdentifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func canLoad(from provider: NSItemProvider) -> Bool {
        if let suggestedName = provider.suggestedName,
           UUID(uuidString: suggestedName) != nil
        {
            return true
        }
        return acceptedTypes.contains { type in
            provider.hasItemConformingToTypeIdentifier(type.identifier)
        }
    }

    static func loadHostID(
        from provider: NSItemProvider,
        completion: @escaping @Sendable (UUID?) -> Void
    ) {
        if let suggestedName = provider.suggestedName,
           let id = UUID(uuidString: suggestedName)
        {
            completion(id)
            return
        }
        guard let typeIdentifier = acceptedTypes
            .map(\.identifier)
            .first(where: provider.hasItemConformingToTypeIdentifier)
        else {
            completion(nil)
            return
        }
        provider.loadDataRepresentation(
            forTypeIdentifier: typeIdentifier
        ) { data, _ in
            completion(data.flatMap(hostID(from:)))
        }
    }

    static func hostID(from data: Data) -> UUID? {
        String(data: data, encoding: .utf8)
            .flatMap(UUID.init(uuidString:))
    }
}

enum HostGroupDragPayload {
    static let typeIdentifier = UTType.termPilotHostGroupID.identifier
    static let fallbackTypeIdentifier = UTType.plainText.identifier
    static let acceptedTypes: [UTType] = [.termPilotHostGroupID, .plainText]

    static func provider(for groupID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(groupID.uuidString.utf8)
        let fallbackData = Data("group:\(groupID.uuidString)".utf8)
        provider.suggestedName = "group-\(groupID.uuidString)"
        provider.registerDataRepresentation(
            forTypeIdentifier: typeIdentifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: fallbackTypeIdentifier,
            visibility: .all
        ) { completion in
            completion(fallbackData, nil)
            return nil
        }
        return provider
    }

    static func canLoad(from provider: NSItemProvider) -> Bool {
        if let suggestedName = provider.suggestedName,
           suggestedName.hasPrefix("group-")
        {
            return true
        }
        return provider.hasItemConformingToTypeIdentifier(typeIdentifier)
    }

    static func loadGroupID(
        from provider: NSItemProvider,
        completion: @escaping @Sendable (UUID?) -> Void
    ) {
        if let suggestedName = provider.suggestedName,
           suggestedName.hasPrefix("group-")
        {
            completion(
                UUID(
                    uuidString: String(suggestedName.dropFirst("group-".count))
                )
            )
            return
        }
        if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            provider.loadDataRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { data, _ in
                completion(data.flatMap(groupID(from:)))
            }
            return
        }
        guard provider.hasItemConformingToTypeIdentifier(fallbackTypeIdentifier)
        else {
            completion(nil)
            return
        }
        provider.loadDataRepresentation(
            forTypeIdentifier: fallbackTypeIdentifier
        ) { data, _ in
            completion(data.flatMap(fallbackGroupID(from:)))
        }
    }

    static func groupID(from data: Data) -> UUID? {
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        if value.hasPrefix("group:") {
            return UUID(uuidString: String(value.dropFirst("group:".count)))
        }
        return UUID(uuidString: value)
    }

    static func fallbackGroupID(from data: Data) -> UUID? {
        guard let value = String(data: data, encoding: .utf8),
              value.hasPrefix("group:")
        else {
            return nil
        }
        return UUID(uuidString: String(value.dropFirst("group:".count)))
    }
}

enum HostTreeDragPayload {
    static let acceptedTypes: [UTType] = [
        .termPilotHostGroupID,
        .termPilotHostID,
        .plainText,
    ]

    static func loadItem(
        from provider: NSItemProvider,
        completion: @escaping @Sendable (HostTreeDragItem?) -> Void
    ) {
        if HostGroupDragPayload.canLoad(from: provider) {
            HostGroupDragPayload.loadGroupID(from: provider) { groupID in
                completion(groupID.map(HostTreeDragItem.group))
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(
            HostDragPayload.typeIdentifier
        ) {
            loadHostItem(from: provider, completion: completion)
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.plainText.identifier
            ) { data, _ in
                if let groupID = data.flatMap(
                    HostGroupDragPayload.fallbackGroupID(from:)
                ) {
                    completion(.group(groupID))
                } else if let hostID = data.flatMap(HostDragPayload.hostID(from:)) {
                    completion(.host(hostID))
                } else {
                    completion(nil)
                }
            }
            return
        }
        completion(nil)
    }

    private static func loadHostItem(
        from provider: NSItemProvider,
        completion: @escaping @Sendable (HostTreeDragItem?) -> Void
    ) {
        guard HostDragPayload.canLoad(from: provider) else {
            completion(nil)
            return
        }
        HostDragPayload.loadHostID(from: provider) { hostID in
            completion(hostID.map(HostTreeDragItem.host))
        }
    }
}

enum HostTreeDragItem {
    case host(UUID)
    case group(UUID)
}
