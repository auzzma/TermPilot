import SwiftUI
import TermPilotDomain

struct HostGroupManagerView: View {
    @EnvironmentObject private var state: AppState
    @State private var newGroupName = ""
    @State private var parentGroupID: UUID?
    @State private var collapsedGroupIDs = Set<UUID>()
    @State private var deletingGroup: HostGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("New group", text: $newGroupName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addGroup)
                    Button("Add", action: addGroup)
                        .disabled(
                            newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
                Picker("Parent Group", selection: $parentGroupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(HostGroupHierarchy.flattenedOptions(from: state.groups)) { option in
                        Text(option.displayName).tag(Optional(option.group.id))
                    }
                }
            }

            List {
                ForEach(visibleGroupRows) { row in
                    groupRow(row)
                }
            }
            .overlay {
                if state.groups.isEmpty {
                    ContentUnavailableView(
                        "No Groups",
                        systemImage: "folder",
                        description: Text("Groups organize saved hosts.")
                    )
                }
            }
        }
        .padding(20)
        .sheet(item: $deletingGroup) { group in
            DeleteHostGroupSheet(
                group: group,
                onCancel: {
                    deletingGroup = nil
                },
                onDelete: {
                    deleteGroup(group)
                }
            )
        }
    }

    private var visibleGroupRows: [VisibleGroupRow] {
        var rows: [VisibleGroupRow] = []
        func append(_ node: HostGroupNode, depth: Int) {
            rows.append(
                VisibleGroupRow(
                    group: node.group,
                    depth: depth,
                    hasChildren: !node.children.isEmpty
                )
            )
            guard !collapsedGroupIDs.contains(node.id) else {
                return
            }
            for child in node.children {
                append(child, depth: depth + 1)
            }
        }
        for root in HostGroupHierarchy.roots(from: state.groups) {
            append(root, depth: 0)
        }
        return rows
    }

    private func groupRow(_ row: VisibleGroupRow) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleGroup(row.group.id)
            } label: {
                Image(
                    systemName: collapsedGroupIDs.contains(row.group.id)
                        ? "chevron.right"
                        : "chevron.down"
                )
                .opacity(row.hasChildren ? 1 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!row.hasChildren)

            Image(systemName: "folder")
            Text(row.group.name)
            Spacer()
            Menu {
                Button("None") {
                    moveGroup(row.group, parentGroupID: nil)
                }
                let options = validParentOptions(for: row.group)
                if !options.isEmpty {
                    Divider()
                    ForEach(options) { option in
                        Button(option.displayName) {
                            moveGroup(row.group, parentGroupID: option.group.id)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.turn.down.right")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel("Move Group")
            Button(role: .destructive) {
                deletingGroup = row.group
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete Group")
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.hasChildren {
                toggleGroup(row.group.id)
            }
        }
    }

    private func deleteGroup(_ group: HostGroup) {
        let removedGroupIDs = HostGroupHierarchy.groupIDs(
            includingDescendantsOf: group.id,
            groups: state.groups
        )
        if let parentGroupID,
           removedGroupIDs.contains(parentGroupID)
        {
            self.parentGroupID = nil
        }
        collapsedGroupIDs.subtract(removedGroupIDs)
        deletingGroup = nil
        Task {
            await state.deleteGroup(group)
        }
    }

    private func addGroup() {
        let group = HostGroup(
            name: newGroupName,
            parentGroupID: parentGroupID,
            sortOrder: state.groups.filter {
                $0.parentGroupID == parentGroupID
            }.count
        )
        Task {
            if await state.saveGroup(group) {
                newGroupName = ""
            }
        }
    }

    private func toggleGroup(_ id: UUID) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
    }

    private func moveGroup(_ group: HostGroup, parentGroupID: UUID?) {
        var copy = group
        copy.parentGroupID = parentGroupID
        copy.sortOrder = state.groups.filter {
            $0.parentGroupID == parentGroupID && $0.id != group.id
        }.count
        Task {
            _ = await state.saveGroup(copy)
        }
    }

    private func validParentOptions(for group: HostGroup) -> [HostGroupOption] {
        HostGroupHierarchy.flattenedOptions(from: state.groups).filter { option in
            option.group.id != group.id
                && !isDescendant(option.group.id, of: group.id)
        }
    }

    private func isDescendant(_ candidateID: UUID, of groupID: UUID) -> Bool {
        var parentID = state.groups.first { $0.id == candidateID }?.parentGroupID
        var visited = Set<UUID>()
        while let current = parentID,
              visited.insert(current).inserted
        {
            if current == groupID {
                return true
            }
            parentID = state.groups.first { $0.id == current }?.parentGroupID
        }
        return false
    }
}

private struct VisibleGroupRow: Identifiable {
    var group: HostGroup
    var depth: Int
    var hasChildren: Bool

    var id: UUID { group.id }
}
