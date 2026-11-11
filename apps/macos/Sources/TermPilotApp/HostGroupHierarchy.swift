import Foundation
import TermPilotDomain

struct HostGroupNode: Identifiable {
    var group: HostGroup
    var children: [HostGroupNode]

    var id: UUID { group.id }
}

struct HostGroupOption: Identifiable {
    var group: HostGroup
    var depth: Int

    var id: UUID { group.id }

    var displayName: String {
        "\(String(repeating: "  ", count: depth))\(group.name)"
    }
}

enum HostGroupSelectionState: Equatable {
    case none
    case partial
    case all

    var systemImage: String {
        switch self {
        case .none:
            "square"
        case .partial:
            "minus.square.fill"
        case .all:
            "checkmark.square.fill"
        }
    }
}

enum HostGroupHierarchy {
    static func roots(from groups: [HostGroup]) -> [HostGroupNode] {
        let validIDs = Set(groups.map(\.id))
        let childrenByParent = Dictionary(grouping: groups) { group in
            group.parentGroupID
        }
        var remaining = Set(groups.map(\.id))
        var nodes: [HostGroupNode] = []

        func append(_ group: HostGroup, ancestors: Set<UUID>) -> HostGroupNode {
            remaining.remove(group.id)
            let children = sorted(childrenByParent[group.id] ?? [])
                .filter { !ancestors.contains($0.id) }
                .map { child in
                    append(child, ancestors: ancestors.union([group.id]))
                }
            return HostGroupNode(group: group, children: children)
        }

        let roots = sorted(groups).filter { group in
            guard let parentID = group.parentGroupID else {
                return true
            }
            return !validIDs.contains(parentID)
        }
        for group in roots {
            nodes.append(append(group, ancestors: []))
        }

        for group in sorted(groups).filter({ remaining.contains($0.id) }) {
            nodes.append(append(group, ancestors: []))
        }
        return nodes
    }

    static func flattenedOptions(from groups: [HostGroup]) -> [HostGroupOption] {
        var options: [HostGroupOption] = []
        func append(_ node: HostGroupNode, depth: Int) {
            options.append(HostGroupOption(group: node.group, depth: depth))
            for child in node.children {
                append(child, depth: depth + 1)
            }
        }
        for root in roots(from: groups) {
            append(root, depth: 0)
        }
        return options
    }

    static func hostIDs(
        includingDescendantsOf groupID: UUID,
        groups: [HostGroup],
        hosts: [TermPilotDomain.Host]
    ) -> Set<UUID> {
        let groupIDs = groupIDs(
            includingDescendantsOf: groupID,
            groups: groups
        )

        return Set(hosts.compactMap { host in
            guard let hostGroupID = host.groupID,
                  groupIDs.contains(hostGroupID)
            else {
                return nil
            }
            return host.id
        })
    }

    static func groupIDs(
        includingDescendantsOf groupID: UUID,
        groups: [HostGroup]
    ) -> Set<UUID> {
        let childrenByParent = Dictionary(grouping: groups) {
            $0.parentGroupID
        }
        var groupIDs = Set<UUID>()
        var pendingGroupIDs = [groupID]

        while let currentGroupID = pendingGroupIDs.popLast() {
            guard groupIDs.insert(currentGroupID).inserted else {
                continue
            }
            pendingGroupIDs.append(
                contentsOf: (childrenByParent[currentGroupID] ?? []).map(\.id)
            )
        }
        return groupIDs
    }

    static func selectionState(
        hostIDs: Set<UUID>,
        selectedHostIDs: Set<UUID>
    ) -> HostGroupSelectionState {
        guard !hostIDs.isEmpty else {
            return .none
        }
        let selectedCount = hostIDs.intersection(selectedHostIDs).count
        if selectedCount == 0 {
            return .none
        }
        return selectedCount == hostIDs.count ? .all : .partial
    }

    private static func sorted(_ groups: [HostGroup]) -> [HostGroup] {
        groups.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
