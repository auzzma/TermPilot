import SwiftUI
import TermPilotDomain

struct BatchHostPicker: View {
    let hosts: [TermPilotDomain.Host]
    let groups: [HostGroup]
    let added: [TermPilotDomain.Host]
    let onAdd: ([TermPilotDomain.Host]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = Set<UUID>()
    @State private var expanded = Set<String>()
    private var available: [TermPilotDomain.Host] { batchSelectableHosts(hosts) }
    private var already: Set<UUID> {
        let endpoints = Set(added.map(batchHostEndpoint))
        return Set(available.filter { endpoints.contains(batchHostEndpoint($0)) }.map(\.id))
    }
    private var shown: [TermPilotDomain.Host] { batchMatchingHosts(available, groups: groups, query: query) }
    private var selectedHosts: [TermPilotDomain.Host] { available.filter { selected.contains($0.id) && !already.contains($0.id) } }
    private var chosenHosts: [TermPilotDomain.Host] { available.filter { selected.contains($0.id) || already.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppLocalization.string("Add saved host")).font(.title2.bold())
            Text(AppLocalization.string("Expand groups to select hosts, or select a whole group including its subgroups.")).foregroundStyle(.secondary)
            TextField(AppLocalization.string("Search hosts or groups"), text: $query).textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, value in
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { expanded = Set(groups.map { $0.id.uuidString }).union(["ungrouped"]) }
                }
            HStack {
                Button(AppLocalization.string(query.isEmpty ? "Select all hosts" : "Select matching hosts")) { selected.formUnion(Set(shown.map(\.id)).subtracting(already)) }
                Button(AppLocalization.string("Clear selection")) { selected.removeAll() }
                Spacer()
                Text("\(selectedHosts.count) \(AppLocalization.string("hosts to add"))").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    Text(AppLocalization.string("Groups")).font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(batchHostTreeRows(hosts: available, groups: groups, query: query, expanded: expanded)) { row in
                                treeRow(row).padding(.leading, CGFloat(row.depth) * 16)
                            }
                            if shown.isEmpty { Text(AppLocalization.string("No matching SSH hosts")).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading) {
                    HStack { Text(AppLocalization.string("Selected hosts")).font(.headline); Spacer(); Text("\(chosenHosts.count)").foregroundStyle(.secondary) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(chosenHosts) { host in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        hostLabel(host)
                                        Text(batchGroupPath(host.groupID, groups: groups).isEmpty ? AppLocalization.string("Ungrouped") : batchGroupPath(host.groupID, groups: groups)).font(.caption).foregroundStyle(.secondary)
                                        if already.contains(host.id) { Text(AppLocalization.string("Already added")).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 0)
                                    if !already.contains(host.id) {
                                        Button { selected.remove(host.id) } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("\(AppLocalization.string("Remove")) \(host.label)")
                                    }
                                }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                            }
                            if chosenHosts.isEmpty { Text(AppLocalization.string("Select hosts from the groups on the left.")).foregroundStyle(.secondary).padding(.top, 8) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 360)
            HStack {
                Spacer()
                Button(AppLocalization.string("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button { onAdd(selectedHosts); dismiss() } label: { Text("\(AppLocalization.string("Add selected hosts")) (\(selectedHosts.count))") }
                    .buttonStyle(.borderedProminent).disabled(selectedHosts.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 820)
        .onAppear { expanded = Set(HostGroupHierarchy.roots(from: groups).map { $0.id.uuidString }).union(["ungrouped"]) }
    }
    @ViewBuilder private func treeRow(_ row: BatchHostTreeRow) -> some View {
        if let host = row.host {
            Button { toggle(row.hostIDs) } label: {
                HStack(alignment: .top, spacing: 8) {
                    selectionIcon(row.hostIDs)
                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        hostLabel(host)
                        if already.contains(host.id) { Text(AppLocalization.string("Already added")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(already.contains(host.id))
                .accessibilityLabel("\(host.label) \(host.hostname)").accessibilityValue(selectionLabel(row.hostIDs))
        } else {
            let name = row.group?.name ?? AppLocalization.string("Ungrouped")
            HStack(spacing: 8) {
                Button { toggleExpanded(row.id) } label: { Image(systemName: row.expanded ? "chevron.down" : "chevron.right").frame(width: 12) }
                    .buttonStyle(.plain).accessibilityLabel("\(AppLocalization.string(row.expanded ? "Collapse group" : "Expand group")) \(name)")
                Button { toggle(row.hostIDs) } label: { selectionIcon(row.hostIDs) }
                    .buttonStyle(.plain).disabled(row.hostIDs.isSubset(of: already)).accessibilityLabel(name).accessibilityValue(selectionLabel(row.hostIDs))
                Button { toggleExpanded(row.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(name).fontWeight(.semibold).lineLimit(2)
                        Spacer(minLength: 0)
                        Text("\(row.hostIDs.intersection(selected.union(already)).count) / \(row.hostIDs.count)").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
    private func hostLabel(_ host: TermPilotDomain.Host) -> some View {
        let address = host.hostname.contains(":") ? "[\(host.hostname)]" : host.hostname
        return VStack(alignment: .leading, spacing: 3) {
            Text(host.label).lineLimit(2).help(host.label)
            Text("\(address):\(host.port)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    private func selectionIcon(_ ids: Set<UUID>) -> some View {
        let count = ids.intersection(selected.union(already)).count
        return Image(systemName: count == ids.count ? "checkmark.square.fill" : count > 0 ? "minus.square.fill" : "square")
            .foregroundStyle(count > 0 ? Color.accentColor : Color.secondary)
    }
    private func selectionLabel(_ ids: Set<UUID>) -> String {
        let count = ids.intersection(selected.union(already)).count
        return AppLocalization.string(count == ids.count ? "Selected" : count > 0 ? "Partially selected" : "Not selected")
    }
    private func toggle(_ ids: Set<UUID>) { selected = batchToggleSelection(selected, ids: ids, alreadyAdded: already) }
    private func toggleExpanded(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
}
